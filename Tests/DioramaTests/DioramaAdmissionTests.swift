import Diorama
import DioramaCore
import Dispatch
import Synchronization
import Testing

/// Synchronous startup and cleanup gates occupy one worker at a time.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DioramaAdmissionTests {
    @Test(arguments: ["startup", "body", "cleanup", "rollback"])
    func `overlap is rejected throughout the admitted attempt`(phase: String) async throws {
        let gate = AdmissionTestGate()
        defer { gate.release() }
        let preparations = Mutex(0)
        let system = try ScenarioSystem(
            type: DioramaFixtures.type, attachment: ScenarioAttachment(id: DioramaFixtures.attachment("a")))
        { _ in
            preparations.withLock { $0 += 1 }
            if phase == "startup" {
                gate.pause()
            }
            return PreparedSystem {
                ActivatedSystem(dependency: true) {
                    if phase == "cleanup" || phase == "rollback" {
                        gate.pause()
                    }
                }
            }
        }
        let second = try secondSystem(fails: phase == "rollback")
        let setup = try Diorama(scenarioID: "admission", mode: .record, systems: system, second)
        let alias = setup
        let first = Task {
            try await setup.execute { _, _, _ in
                if phase == "body" {
                    gate.pause()
                }
            }
        }
        await gate.waitUntilEntered()
        #expect(alias.report == nil)
        await #expect(throws: DioramaExecutionError.executionAlreadyInProgress) {
            try await alias.execute { _, _, _ in Issue.record("Rejected execution invoked its body") }
        }
        #expect(preparations.withLock { $0 } == 1)
        #expect(alias.report == nil)
        gate.release()
        do {
            let result = try await first.value
            #expect(phase != "rollback")
            #expect(setup.report == result.report)
            #expect(result.report.diagnostics.isEmpty)
        } catch let failure as ScenarioStartupFailure {
            #expect(phase == "rollback")
            #expect(failure.cleanup.map(\.disposition) == [.completed])
            #expect(setup.report == nil)
        }
    }

    @Test
    func `nested calls reject immediately without polluting the outer report`() async throws {
        let setup = try Diorama(scenarioID: "nested", mode: .record)
        let result = try await setup.execute { _ in
            await #expect(throws: DioramaExecutionError.executionAlreadyInProgress) {
                try await setup.execute { _ in Issue.record("Nested body ran") }
            }
            #expect(setup.report == nil)
            return 7
        }
        #expect(result.body == 7)
        #expect(result.report.diagnostics.isEmpty)
        #expect(setup.report == result.report)
    }

    @Test
    func `separate instances execute concurrently`() async throws {
        let firstSetup = try Diorama(scenarioID: "first", mode: .record)
        let secondSetup = try Diorama(scenarioID: "second", mode: .record)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let first = Task {
            try await firstSetup.execute { _ in
                entered.continuation.yield(())
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
        }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        let second = try await secondSetup.execute { _ in
            #expect(firstSetup.report == nil)
            #expect(secondSetup.report == nil)
        }
        #expect(secondSetup.report == second.report)
        release.continuation.finish()
        let firstResult = try await first.value
        #expect(firstSetup.report == firstResult.report)
    }

    @Test
    func `cancellation keeps admission closed until cleanup completes`() async throws {
        let gate = AdmissionTestGate()
        defer { gate.release() }
        let cleanupCount = Mutex(0)
        let system = try ScenarioSystem(
            type: DioramaFixtures.type, attachment: ScenarioAttachment(id: DioramaFixtures.attachment("a")))
        { _ in
            PreparedSystem {
                ActivatedSystem(dependency: true) {
                    let count = cleanupCount.withLock { count in
                        count += 1
                        return count
                    }
                    if count == 1 {
                        gate.pause()
                    }
                }
            }
        }
        let setup = try Diorama(scenarioID: "cancel", mode: .record, systems: system)
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            try await setup.execute { _, _ in
                started.continuation.yield(())
                try await Task.sleep(for: .seconds(60))
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await gate.waitUntilEntered()
        #expect(setup.report == nil)
        await #expect(throws: DioramaExecutionError.executionAlreadyInProgress) {
            try await setup.execute { _, _ in Issue.record("Canceled run released admission too early") }
        }
        gate.release()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
            #expect(setup.report != nil)
        }
        let next = try await setup.execute { _, value in value }
        #expect(next.body)
        #expect(setup.report == next.report)
        #expect(cleanupCount.withLock { $0 } == 2)
    }

    private func secondSystem(fails: Bool) throws -> ScenarioSystem<Bool> {
        try ScenarioSystem(
            type: DioramaFixtures.type, attachment: ScenarioAttachment(id: DioramaFixtures.attachment("b")))
        { _ in
            PreparedSystem {
                if fails {
                    throw AdmissionTestFailure.startup
                }
                return ActivatedSystem(dependency: true, deactivate: {})
            }
        }
    }
}

private enum AdmissionTestFailure: Error { case startup }

private final class AdmissionTestGate: Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let semaphore = DispatchSemaphore(value: 0)

    func pause() {
        entered.continuation.yield(())
        #expect(semaphore.wait(timeout: .now() + 10) == .success)
    }

    func waitUntilEntered() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        semaphore.signal()
    }
}
