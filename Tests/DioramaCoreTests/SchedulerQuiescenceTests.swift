@testable import DioramaCore
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SchedulerQuiescenceTests {
    @Test
    func `suspended async delivery does not block later handoffs or timer selection`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let lease = systems[0].scheduling
        let gate = SchedulerDeliveryGate()
        defer { gate.release() }
        let journal = SchedulerJournal()
        let first = try lease.schedule(after: .zero, for: SchedulerFixtures.record()) {
            await gate.suspend()
            journal.append("first")
        }
        await gate.waitForEntry()
        #expect(first.registration.phase == .claimed)
        #expect(!first.cancel())
        let second = try lease.schedule(after: .seconds(10), for: SchedulerFixtures.record()) {
            journal.append("second")
        }
        #expect(try await clock.nextSleep().deadline == .seconds(10))
        clock.advance(to: .seconds(10))
        #expect(await journal.take(1) == ["second"])
        #expect(first.registration.phase == .claimed)
        gate.release()
        #expect(await execution.finish().report.diagnostics.isEmpty)
        #expect(journal.values == ["second", "first"])
        #expect(first.registration.phase == .completed)
        #expect(second.registration.phase == .completed)
    }

    @Test(arguments: [false, true])
    func `finish joins scoped async delivery despite canceled waiters`(alreadyCanceled: Bool) async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let lease = systems[0].scheduling
        let gate = SchedulerDeliveryGate()
        defer { gate.release() }
        let returned = Mutex(false)
        let first = try lease.schedule(after: .zero, for: SchedulerFixtures.record()) {
            await gate.suspend()
            await deliver(on: lease, execution: execution, returned: returned)
        }
        await gate.waitForEntry()
        let stopped = SchedulerJournal()
        let pending = try registerPendingMarker(on: lease, stopped: stopped)
        let oldWait = try await clock.nextSleep()
        let finish = Task {
            if alreadyCanceled {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            let result = await execution.finish()
            returned.withLock { $0 = true }
            return result
        }
        #expect(await stopped.take(1) == ["stopped"])
        finish.cancel()
        #expect(try await clock.nextCancellation() == .seconds(10))
        let repeated = Task { await execution.finish() }
        repeated.cancel()
        #expect(!returned.withLock { $0 })
        #expect(first.registration.phase == .claimed)
        #expect(pending.registration.phase == .canceled)
        #expect(!first.cancel())
        #expect(!pending.cancel())
        gate.release()
        let result = await finish.value
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .system(DiagnosticLabel("delivery-completed")), .scheduling(.logicalTime(.executionClosed)),
        ])
        #expect(await repeated.value.report == result.report)
        #expect(first.registration.phase == .completed)
        #expect(first.registration.engine == nil)
        #expect(clock.activeWaits == 0)
        await assertClosed(lease, execution: execution, result: result, clock: clock, oldWait: oldWait)
    }

    @MainActor
    private func deliver(on lease: SchedulingLease, execution: ScenarioExecution, returned: borrowing Mutex<Bool>) {
        #expect(!Task.isCancelled)
        #expect(!returned.withLock { $0 })
        #expect(throws: SchedulingFailure.self) {
            try lease.schedule(after: .zero, for: SchedulerFixtures.record()) { Issue.record("Closed delivery") }
        }
        execution.reporter.record(Diagnostic(issue: .system(DiagnosticLabel("delivery-completed"))))
    }

    private func assertClosed(_ lease: SchedulingLease, execution: ScenarioExecution,
                              result: ScenarioFinalizationResult, clock: SchedulerTestClock,
                              oldWait: SchedulerTestClock.Sleep) async
    {
        oldWait.resume.finish()
        clock.advance(to: .seconds(100))
        #expect(throws: SchedulingFailure.self) {
            try lease.schedule(after: .zero, for: SchedulerFixtures.record()) { Issue.record("Late delivery") }
        }
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [
            .scheduling(.logicalTime(.executionClosed)),
        ])
        #expect(await execution.finish().report == result.report)
        #expect(clock.activeWaits == 0)
    }

    @Test
    func `finish joins every concurrently completing async scope`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let lease = systems[0].scheduling
        let gates = (0..<32).map { _ in SchedulerDeliveryGate() }
        defer { for gate in gates {
            gate.release()
        } }
        let handles = try gates.enumerated().map { sequence, gate in
            try lease.schedule(at: .seconds(1), for: SchedulerFixtures.record(sequence: UInt64(sequence))) {
                await gate.suspend()
            }
        }
        clock.advance(to: .seconds(1))
        for gate in gates {
            await gate.waitForEntry()
        }
        let stopped = SchedulerJournal()
        _ = try registerPendingMarker(on: lease, stopped: stopped)
        _ = try await clock.nextSleep()
        let finish = Task { await execution.finish() }
        #expect(await stopped.take(1) == ["stopped"])
        _ = try await clock.nextCancellation()
        await withTaskGroup(of: Void.self) { group in
            for gate in gates {
                group.addTask { gate.release() }
            }
        }
        #expect(await finish.value.report.diagnostics.isEmpty)
        #expect(handles.allSatisfy { $0.registration.phase == .completed })
    }

    @Test(arguments: [false, true])
    func `async early return and handled cancellation complete automatically`(cancel: Bool) async throws {
        let (execution, systems) = try SchedulerFixtures.setup()
        let gate = SchedulerDeliveryGate()
        defer { gate.release() }
        let handle = try systems[0].scheduling.schedule(at: .zero, for: SchedulerFixtures.record()) {
            await gate.suspend()
            guard cancel else { return }
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try Task.checkCancellation()
                Issue.record("The delivery task must observe its own cancellation")
            } catch is CancellationError {
                return
            } catch {
                Issue.record(error)
            }
        }
        await gate.waitForEntry()
        let finish = Task { await execution.finish() }
        gate.release()
        #expect(await finish.value.report.diagnostics.isEmpty)
        #expect(handle.registration.phase == .completed)
    }

    private func registerPendingMarker(on lease: SchedulingLease, stopped: SchedulerJournal)
        throws -> ScheduledItemHandle
    {
        let marker = SchedulerReleaseMarker { stopped.append("stopped") }
        return try lease.schedule(after: .seconds(10), for: SchedulerFixtures.record()) {
            withExtendedLifetime(marker) { _ = Issue.record("Pending callback must not run") }
        }
    }
}
