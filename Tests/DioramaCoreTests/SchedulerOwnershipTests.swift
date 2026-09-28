@testable import DioramaCore
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SchedulerOwnershipTests {
    private struct EscapedHandle {
        let handle: ScheduledItemHandle
        weak var engine: DeadlineEngine?
        weak var time: ExecutionTime?
        weak var execution: ScenarioExecution?
        weak var reporter: DiagnosticReporter?
    }

    @Test
    func `escaped terminal handles release scheduler execution and reporting ownership`() async throws {
        let tokens = try await finishedHandle()
        #expect(tokens.engine == nil)
        #expect(tokens.time == nil)
        #expect(tokens.execution == nil)
        #expect(tokens.reporter == nil)
        #expect(!tokens.handle.cancel())
    }

    private func finishedHandle() async throws -> EscapedHandle {
        let (execution, systems) = try SchedulerFixtures.setup()
        let gate = SchedulerDeliveryGate()
        defer { gate.release() }
        let handle = try systems[0].scheduling.schedule(after: .zero, for: SchedulerFixtures.record()) {
            await gate.suspend()
        }
        await gate.waitForEntry()
        let tokens = EscapedHandle(handle: handle,
                                   engine: handle.registration.engine, time: systems[0].time,
                                   execution: execution, reporter: execution.reporter)
        gate.release()
        #expect(await execution.finish().report.diagnostics.isEmpty)
        return tokens
    }

    @Test
    func `clock failure cancels pending items but still drains claimed delivery`() async throws {
        let clock = SchedulerTestClock()
        let diagnostics = AsyncStream<Diagnostic>.makeStream()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source, sink: DiagnosticSink {
            diagnostics.continuation.yield($0.diagnostic)
        })
        let gate = SchedulerDeliveryGate()
        defer { gate.release() }
        let lease = systems[0].scheduling
        let claimed = try lease.schedule(after: .zero, for: SchedulerFixtures.record()) {
            await gate.suspend()
        }
        await gate.waitForEntry()
        let pending = try lease.schedule(after: .seconds(10), for: SchedulerFixtures.record()) {
            Issue.record("Clock failure must stop pending delivery")
        }
        _ = try await clock.nextSleep()
        clock.advance(to: .seconds(-1), early: true)
        var diagnosticIterator = diagnostics.stream.makeAsyncIterator()
        #expect(await diagnosticIterator.next()?.issue == .scheduling(.logicalTime(.clockMovedBackward)))
        #expect(pending.registration.phase == .canceled)
        #expect(claimed.registration.phase == .claimed)
        #expect(!pending.cancel())
        let finish = Task { await execution.finish() }
        gate.release()
        #expect(await finish.value.report.diagnostics.count == 1)
        #expect(claimed.registration.phase == .completed)
        #expect(clock.activeWaits == 0)
    }

    @Test
    func `delivery captures release before final result freeze`() async throws {
        let (execution, systems) = try SchedulerFixtures.setup()
        let entry = SchedulerJournal()
        try scheduleMarker(on: systems[0].scheduling, reporter: execution.reporter, entry: entry)
        #expect(await entry.take(1) == ["entered"])
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.system(DiagnosticLabel("capture-released"))])
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
    }

    private func scheduleMarker(on lease: SchedulingLease, reporter: DiagnosticReporter,
                                entry: SchedulerJournal) throws
    {
        let marker = SchedulerReleaseMarker {
            reporter.record(Diagnostic(issue: .system(DiagnosticLabel("capture-released"))))
        }
        let body: @Sendable () async -> Void = {
            entry.append("entered")
            withExtendedLifetime(marker) {}
        }
        try lease.schedule(after: .zero, for: SchedulerFixtures.record(), delivery: body)
    }
}
