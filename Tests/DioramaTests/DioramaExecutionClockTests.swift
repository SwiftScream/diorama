import Diorama
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DioramaExecutionClockTests {
    private enum BodyFailure: Error, Equatable { case stopped }

    @Test
    func `consumer gets execution context without a system import or declaration`() async throws {
        let setup = try Diorama(scenarioID: "clock-only", mode: .record)
        let result = try await setup.execute { context in
            let before = context.clock.now
            try await context.clock.sleep(for: .milliseconds(1))
            #expect(before < context.clock.now)
            return context
        }
        #expect(result.definition?.attachments.isEmpty == true)
        #expect(result.finalization.usage.isEmpty)
        #expect(result.report.diagnostics.isEmpty)
        let frozen = result.body.clock.now
        #expect(result.body.clock.now == frozen)
        await #expect(throws: (any Error).self) {
            try await result.body.clock.sleep(for: .milliseconds(1))
        }
        #expect(result.report.diagnostics.isEmpty)
    }

    @MainActor
    @Test
    func `context scope preserves typed dependencies actor isolation and body errors`() async throws {
        var count = 0
        let probe = DioramaSetupProbe()
        let setup = try Diorama(scenarioID: "clock-and-system", mode: .record, systems: probe.system("a"))
        await #expect(throws: BodyFailure.stopped) {
            _ = try await setup.execute { context, lease async throws(BodyFailure) -> Int in
                MainActor.preconditionIsolated()
                count += 1
                #expect(context.clock.now.offset >= .zero)
                #expect(!lease.isClosed)
                throw .stopped
            }
        }
        #expect(count == 1)
        #expect(probe.events.withLock { $0.last } == "cleanup-a")
    }

    @Test
    func `canceling a scoped clock sleep still finalizes configured systems`() async throws {
        let probe = DioramaSetupProbe()
        let setup = try Diorama(scenarioID: "cancel-clock", mode: .record, systems: probe.system("a"))
        let started = AsyncStream<Void>.makeStream()
        let operation = Task {
            try await setup.execute { context, _ in
                started.continuation.finish()
                try await context.clock.sleep(for: .seconds(100))
            }
        }
        for await _ in started.stream {}
        operation.cancel()
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(probe.events.withLock { $0.last } == "cleanup-a")
    }
}
