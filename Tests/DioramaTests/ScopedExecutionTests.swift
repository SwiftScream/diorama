import Diorama
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
        let journal = DioramaFixtures.Journal()

        let definition = try DioramaFixtures.definition(["a", "b", "c"])
        let first = try system("a", dependency: 42, journal: journal)
        let second = try system("b", dependency: "text", journal: journal)
        let third = try system("c", dependency: true, journal: journal)

        let scoped = try await Diorama(
            definition: definition,
            scenarioID: "execution", mode: .replay,
            systems: third,
            first,
            second).execute { flag, number, text in
            "\(flag)-\(number)-\(text)"
        }

        #expect(scoped.body == "true-42-text")
        #expect(scoped.finalization.report.diagnostics.isEmpty)
        #expect(journal.events.withLock { $0 } == [
            "prepare-c", "prepare-a", "prepare-b",
            "activate-c", "activate-a", "activate-b",
            "cleanup-b", "cleanup-a", "cleanup-c",
        ])
    }

    @MainActor
    @Test
    func `variadic body preserves caller actor isolation`() async throws {
        let journal = DioramaFixtures.Journal()

        let definition = try DioramaFixtures.definition(["a"])
        let instance = try system("a", dependency: 42, journal: journal)
        let state = MainActorState()

        let scoped = try await Diorama(definition: definition, scenarioID: "execution", mode: .replay,
                                       systems: instance).execute { value in
            state.values.append(value)
            return state.values.count
        }

        #expect(scoped.body == 1)
        #expect(state.values == [42])
    }

    @Test
    func `body failure propagates after cleanup`() async throws {
        let journal = DioramaFixtures.Journal()

        let definition = try DioramaFixtures.definition(["a", "b"])
        let first = try system("a", dependency: 1, journal: journal)
        let second = try system("b", dependency: 2, journal: journal, failCleanup: true)

        let setup = try Diorama(
            definition: definition, scenarioID: "execution", mode: .replay,
            systems: first, second)
        await #expect(throws: BodyFailure.stopped) {
            _ = try await setup.execute { first, second async throws(BodyFailure) -> Int in
                #expect(first == 1)
                #expect(second == 2)
                throw .stopped
            }
        }
        #expect(journal.events.withLock { $0.suffix(2) } == ["cleanup-b", "cleanup-a"])
    }

    @Test
    func `cleanup failure remains in finalization when the body succeeds`() async throws {
        let journal = DioramaFixtures.Journal()
        let definition = try DioramaFixtures.definition(["a"])
        let instance = try system("a", dependency: 1, journal: journal, failCleanup: true)
        let result = try await Diorama(definition: definition, scenarioID: "execution", mode: .replay,
                                       systems: instance).execute { value in value }
        #expect(result.body == 1)
        #expect(result.finalization.cleanup.map(\.disposition) == [.failed])
        #expect(result.finalization.report.diagnostics.map(\.diagnostic.issue) == [.lifecycle(.cleanupFailed)])
    }

    @Test
    func `body cancellation still completes finalization`() async throws {
        let journal = DioramaFixtures.Journal()

        let definition = try DioramaFixtures.definition(["a"])
        let instance = try system("a", dependency: 1, journal: journal, expectUncancelledCleanup: true)
        let started = AsyncStream<Void>.makeStream()

        let task = Task {
            try await Diorama(definition: definition, scenarioID: "execution", mode: .replay, systems: instance)
                .execute { value async throws -> Int in
                    started.continuation.yield(())
                    try await Task.sleep(for: .seconds(10))
                    return value
                }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A canceled sleep unexpectedly returned")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(journal.events.withLock { $0.last } == "cleanup-a")
    }

    @Test
    func `caller cancellation still completes finalization when the body returns`() async throws {
        let journal = DioramaFixtures.Journal()

        let definition = try DioramaFixtures.definition(["a"])
        let instance = try system("a", dependency: 1, journal: journal, expectUncancelledCleanup: true)
        let started = AsyncStream<Void>.makeStream()
        let blocker = AsyncStream<Void>.makeStream()

        let task = Task {
            try await Diorama(definition: definition, scenarioID: "execution", mode: .replay, systems: instance)
                .execute { value in
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

        #expect(scoped.body == 1)
        #expect(scoped.finalization.cleanup.map(\.disposition) == [.completed])
    }

    @Test
    func `startup failure throws without invoking a scoped body`() async throws {
        let instance = try system("a", dependency: 1, journal: DioramaFixtures.Journal())
        let setup = try Diorama(scenarioID: "execution", mode: .replay, systems: instance)
        let bodyCalls = Mutex(0)

        await #expect(throws: ScenarioStartupFailure.self) {
            _ = try await setup.execute { _ in
                bodyCalls.withLock { $0 += 1 }
            }
        }
        #expect(bodyCalls.withLock { $0 } == 0)
    }

    private func system<Dependency: Sendable>(
        _ key: String,
        dependency: Dependency,
        journal: DioramaFixtures.Journal,
        failCleanup: Bool = false,
        expectUncancelledCleanup: Bool = false) throws -> ScenarioSystem<Dependency>
    {
        try ScenarioSystem(
            type: DioramaFixtures.type,
            attachment: ScenarioAttachment(id: DioramaFixtures.attachment(key)))
        { context in
            journal.events.withLock { $0.append("prepare-" + key) }
            _ = try context.lease(for: DioramaFixtures.track(key), preparation: ValuePreparation<Int>())
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
