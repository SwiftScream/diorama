@testable import DioramaCore
import Dispatch
import Synchronization
import Testing

/// Share the serialized suite with the existing synchronous cleanup races so
/// the two-CPU Linux job always retains a worker to release the blocked handoff.
extension ConcurrentFinalizationTests {
    @Test
    func `finish waits for an already claimed handoff to return`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let gate = HandoffGate()
        defer { gate.release() }
        let journal = SchedulerJournal()
        try registerPendingMarker(on: systems[0].scheduling, journal: journal)
        try systems[0].scheduling.schedule(at: .zero, for: SchedulerFixtures.record()) {
            gate.enter()
            journal.append("handoff-returned")
        }
        await gate.waitForEntry()
        let returned = Mutex(false)
        let finish = Task {
            let result = await execution.finish()
            returned.withLock { $0 = true }
            return result
        }
        // Dropping the pending item proves finish has closed the scheduler and
        // reached its join, without relying on sleeps or executor turn counts.
        #expect(await journal.take(1) == ["pending-released"])
        #expect(!returned.withLock { $0 })
        gate.release()
        let result = await finish.value
        #expect(journal.values == ["pending-released", "handoff-returned"])
        #expect(result.report.diagnostics.isEmpty)
        #expect(clock.activeWaits == 0)
    }

    private func registerPendingMarker(on lease: SchedulingLease, journal: SchedulerJournal) throws {
        let marker = PendingHandoffMarker(journal)
        try lease.schedule(after: .seconds(10), for: SchedulerFixtures.record()) {
            withExtendedLifetime(marker) { _ = Issue.record("Pending delivery must be removed by finish") }
        }
    }
}

private final class PendingHandoffMarker: Sendable {
    let journal: SchedulerJournal

    init(_ journal: SchedulerJournal) {
        self.journal = journal
    }

    deinit { journal.append("pending-released") }
}

private final class HandoffGate: Sendable {
    private let entry = AsyncStream<Void>.makeStream()
    private let semaphore = DispatchSemaphore(value: 0)

    func enter() {
        entry.continuation.yield(())
        #expect(semaphore.wait(timeout: .now() + 10) == .success)
    }

    func waitForEntry() async {
        for await _ in entry.stream {
            return
        }
    }

    func release() {
        semaphore.signal()
    }
}
