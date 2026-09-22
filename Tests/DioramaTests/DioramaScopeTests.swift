import Diorama
import Testing

struct DioramaScopeTests {
    private enum BodyFailure: Error, Equatable { case stopped }

    @MainActor
    private final class ActorState {
        var value = 0
    }

    @MainActor
    @Test
    func `stored declarations preserve actor isolation and typed errors`() async throws {
        let state = ActorState()
        let probe = DioramaSetupProbe()
        let setup = try Diorama(
            scenarioID: "actor", mode: .record,
            systems: probe.system("a"))
        await #expect(throws: BodyFailure.stopped) {
            _ = try await setup.execute { lease async throws(BodyFailure) -> Int in
                state.value += 1
                #expect(!lease.isClosed)
                throw .stopped
            }
        }
        #expect(state.value == 1)
        #expect(probe.events.withLock { $0.last } == "cleanup-a")
    }

    @Test
    func `cancellation finalizes when a scoped body throws or returns`() async throws {
        let probe = DioramaSetupProbe()
        let setup = try Diorama(
            scenarioID: "cancel", mode: .record,
            systems: probe.system("a"))
        for throwsCancellation in [true, false] {
            let started = AsyncStream<Void>.makeStream()
            let blocker = AsyncStream<Void>.makeStream()
            let task = Task {
                try await setup.execute { lease async throws -> Bool in
                    started.continuation.yield(())
                    var iterator = blocker.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    if throwsCancellation {
                        try Task.checkCancellation()
                    }
                    return !lease.isClosed
                }
            }
            var iterator = started.stream.makeAsyncIterator()
            _ = await iterator.next()
            task.cancel()
            blocker.continuation.finish()
            if throwsCancellation {
                do {
                    _ = try await task.value
                    Issue.record("Cancellation was not preserved")
                } catch {
                    #expect(error is CancellationError)
                }
            } else {
                let result = try await task.value
                #expect(result.body)
                #expect(result.finalization.cleanup.map(\.disposition) == [.completed])
            }
        }
        #expect(probe.events.withLock { $0.filter { $0 == "cleanup-a" }.count } == 2)
    }
}
