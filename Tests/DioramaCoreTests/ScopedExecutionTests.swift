import DioramaCore
import Synchronization
import Testing

struct ScopedExecutionTests {
    @MainActor
    private final class MainActorState {
        var values: [Int] = []
    }

    private enum BodyFailure: Error, Equatable {
        case stopped
    }

    @Test
    func `variadic execution injects heterogeneous dependencies in argument order`() async throws {
        let journal = ExecutionFixtures.Journal()
        let definition = try ExecutionFixtures.definition(["a", "b", "c"])
        let first = system("a", dependency: 42, journal: journal)
        let second = system("b", dependency: "text", journal: journal)
        let third = system("c", dependency: true, journal: journal)

        let scoped = try await definition.execute(with: third, first, second) { flag, number, text in
            "\(flag)-\(number)-\(text)"
        }

        switch scoped.body {
        case let .success(value): #expect(value == "true-42-text")
        }
        #expect(scoped.finalization.report.diagnostics.isEmpty)
        #expect(journal.events.withLock { $0 } == [
            "prepare-a", "prepare-b", "prepare-c",
            "activate-a", "activate-b", "activate-c",
            "cleanup-c", "cleanup-b", "cleanup-a",
        ])
    }

    @MainActor
    @Test
    func `variadic body preserves caller actor isolation`() async throws {
        let journal = ExecutionFixtures.Journal()
        let definition = try ExecutionFixtures.definition(["a"])
        let instance = system("a", dependency: 42, journal: journal)
        let state = MainActorState()

        let scoped = try await definition.execute(with: instance) { value in
            state.values.append(value)
            return state.values.count
        }

        #expect(scoped.body == .success(1))
        #expect(state.values == [42])
    }

    @Test
    func `advanced execution preserves body and cleanup failures independently`() async throws {
        let journal = ExecutionFixtures.Journal()
        let definition = try ExecutionFixtures.definition(["a", "b"])
        let first = system("a", dependency: 1, journal: journal)
        let second = system("b", dependency: 2, journal: journal, failCleanup: true)

        let scoped = try await definition.execute(
            with: [AnyScenarioSystem(first), AnyScenarioSystem(second)])
        { execution async throws(BodyFailure) -> Int in
            #expect((try? execution.dependency(first)) == 1)
            throw .stopped
        }

        #expect(scoped.body == .failure(.stopped))
        #expect(scoped.finalization.cleanup.map(\.disposition) == [.completed, .failed])
        #expect(scoped.finalization.report.diagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.cleanupFailed),
        ])
    }

    @Test
    func `body cancellation still completes finalization`() async throws {
        let journal = ExecutionFixtures.Journal()
        let definition = try ExecutionFixtures.definition(["a"])
        let instance = system("a", dependency: 1, journal: journal, expectUncancelledCleanup: true)
        let started = AsyncStream<Void>.makeStream()

        let task = Task {
            try await definition.execute(with: instance) { value async throws -> Int in
                started.continuation.yield(())
                try await Task.sleep(for: .seconds(10))
                return value
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        let scoped = try await task.value

        switch scoped.body {
        case .success:
            Issue.record("A canceled sleep unexpectedly returned")
        case let .failure(error):
            #expect(error is CancellationError)
        }
        #expect(scoped.finalization.cleanup.map(\.disposition) == [.completed])
        #expect(journal.events.withLock { $0.last } == "cleanup-a")
    }

    @Test
    func `caller cancellation still completes finalization when the body returns`() async throws {
        let journal = ExecutionFixtures.Journal()
        let definition = try ExecutionFixtures.definition(["a"])
        let instance = system("a", dependency: 1, journal: journal, expectUncancelledCleanup: true)
        let started = AsyncStream<Void>.makeStream()
        let blocker = AsyncStream<Void>.makeStream()

        let task = Task {
            try await definition.execute(with: instance) { value in
                started.continuation.yield(())
                var iterator = blocker.stream.makeAsyncIterator()
                _ = await iterator.next()
                return value
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        let scoped = try await task.value
        blocker.continuation.finish()

        #expect(scoped.body == .success(1))
        #expect(scoped.finalization.cleanup.map(\.disposition) == [.completed])
    }

    @Test
    func `startup failure throws without invoking a scoped body`() async throws {
        let definition = try ExecutionFixtures.definition(["a"])
        let bodyCalls = Mutex(0)

        await #expect(throws: ScenarioStartupFailure.self) {
            _ = try await definition.execute(with: [AnyScenarioSystem]()) { _ in
                bodyCalls.withLock { $0 += 1 }
            }
        }
        #expect(bodyCalls.withLock { $0 } == 0)
    }

    private func system<Dependency: Sendable>(
        _ key: String,
        dependency: Dependency,
        journal: ExecutionFixtures.Journal,
        failCleanup: Bool = false,
        expectUncancelledCleanup: Bool = false) -> ScenarioSystem<Dependency>
    {
        ScenarioSystem(attachment: ScenarioAttachment(id: ExecutionFixtures.attachment(key))) { context in
            journal.events.withLock { $0.append("prepare-" + key) }
            _ = try context.lease(for: ExecutionFixtures.track(key), preparation: ValuePreparation<Int>())
            return PreparedSystem {
                journal.events.withLock { $0.append("activate-" + key) }
                return ActivatedSystem(dependency: dependency) {
                    if expectUncancelledCleanup {
                        #expect(!Task.isCancelled)
                    }
                    journal.events.withLock { $0.append("cleanup-" + key) }
                    if failCleanup {
                        throw BodyFailure.stopped
                    }
                }
            }
        }
    }
}
