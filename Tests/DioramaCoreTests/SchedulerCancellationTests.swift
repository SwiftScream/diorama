@testable import DioramaCore
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SchedulerCancellationTests {
    @Test
    func `canceling the earliest item replaces the wait and ignores its stale wake`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let lease = systems[0].scheduling
        let journal = SchedulerJournal()
        let first = try lease.schedule(at: .seconds(10), for: SchedulerFixtures.record()) {
            journal.append("unexpected")
        }
        let oldWait = try await clock.nextSleep()
        let next = try lease.schedule(at: .seconds(20), for: SchedulerFixtures.record()) {
            journal.append("next")
        }
        #expect(first.cancel())
        #expect(!first.cancel())
        #expect(first.registration.phase == .canceled)
        #expect(try await clock.nextCancellation() == .seconds(10))
        #expect(try await clock.nextSleep().deadline == .seconds(20))
        oldWait.resume.finish()
        clock.advance(to: .seconds(20))
        #expect(await journal.take(1) == ["next"])
        #expect(await execution.finish().report.diagnostics.isEmpty)
        #expect(next.registration.phase == .completed)
        #expect(!next.cancel())
        #expect(clock.maximumWaits == 1)
        #expect(clock.activeWaits == 0)
    }

    @Test
    func `all due items are claimed before a reentrant cancellation`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let lease = systems[0].scheduling
        let journal = SchedulerJournal()
        let later = Mutex<ScheduledItemHandle?>(nil)
        try lease.schedule(at: .seconds(1), for: SchedulerFixtures.record(sequence: 0)) {
            #expect(later.withLock { $0 }?.cancel() == false)
            journal.append("first")
        }
        let handle = try lease.schedule(at: .seconds(1), for: SchedulerFixtures.record(sequence: 1)) {
            journal.append("second")
        }
        later.withLock { $0 = handle }
        clock.advance(to: .seconds(1))
        #expect(await Set(journal.take(2)) == Set(["first", "second"]))
        #expect(await execution.finish().report.diagnostics.isEmpty)
    }

    @Test
    func `racing cancellation and claim chooses exactly one completion per item`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let lease = systems[0].scheduling
        let registrations = AsyncStream<(ScheduledItemHandle, CheckedContinuation<Bool, Never>)>.makeStream()
        let operations = (0..<128).map { sequence in
            Task {
                await withCheckedContinuation { continuation in
                    do {
                        let handle = try lease.schedule(at: .seconds(1),
                                                        for: SchedulerFixtures.record(sequence: UInt64(sequence)))
                        {
                            continuation.resume(returning: true)
                        }
                        registrations.continuation.yield((handle, continuation))
                    } catch {
                        Issue.record(error)
                        continuation.resume(returning: false)
                        registrations.continuation.finish()
                    }
                }
            }
        }
        var iterator = registrations.stream.makeAsyncIterator()
        var ready: [(ScheduledItemHandle, CheckedContinuation<Bool, Never>)] = []
        for _ in operations {
            try ready.append(#require(await iterator.next()))
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { clock.advance(to: .seconds(1)) }
            for (handle, continuation) in ready {
                // Two cancellation callers race each other and batch claiming.
                for _ in 0..<2 {
                    group.addTask {
                        if handle.cancel() {
                            continuation.resume(returning: false)
                        }
                    }
                }
            }
        }
        var completed = 0
        for operation in operations where await operation.value {
            completed += 1
        }
        #expect(await execution.finish().report.diagnostics.isEmpty)
        #expect(ready.filter { $0.0.registration.phase == .completed }.count == completed)
        #expect(ready.filter { $0.0.registration.phase == .canceled }.count == 128 - completed)
    }

    @Test
    func `cancel releases captures outside isolation while retained handles stay inert`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let lease = systems[0].scheduling
        let journal = SchedulerJournal()
        let handle = try registerMarker(on: lease, journal: journal)
        _ = try await clock.nextSleep()
        #expect(handle.cancel())
        #expect(journal.values == ["released"])
        #expect(try await clock.nextCancellation() == .seconds(10))
        #expect(handle.registration.engine == nil)
        #expect(await execution.finish().report.diagnostics.isEmpty)
    }

    private func registerMarker(on lease: SchedulingLease, journal: SchedulerJournal) throws -> ScheduledItemHandle {
        let marker = SchedulerReleaseMarker {
            // Reentry would deadlock if cancel destroyed this under its lock.
            do {
                let nested = try lease.schedule(after: .seconds(30), for: SchedulerFixtures.record()) {}
                #expect(nested.cancel())
            } catch { Issue.record(error) }
            journal.append("released")
        }
        return try lease.schedule(after: .seconds(10), for: SchedulerFixtures.record()) {
            withExtendedLifetime(marker) { _ = Issue.record("Canceled delivery must not run") }
        }
    }
}

final class SchedulerReleaseMarker: Sendable {
    private let release: @Sendable () -> Void

    init(_ release: @escaping @Sendable () -> Void) {
        self.release = release
    }

    deinit { release() }
}
