@testable import DioramaCore
import Dispatch
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SchedulerDisposalTests {
    @Test
    func `stop cancels registrations but retains captures and sleeps until drainage`() async throws {
        let source = SchedulerTestClock()
        let reporter = try DiagnosticReporter(scenarioID: ScenarioID(rawValue: "stop-drain"),
                                              definition: ScenarioDefinition())
        let admission = ExecutionAdmission()
        let time = ExecutionTime(clock: source.source, admission: admission, reporter: reporter)
        let engine = DeadlineEngine(time: time, admission: admission, reporter: reporter)
        let clock = ScenarioClock(time: time, scheduler: engine, reporter: reporter)
        let journal = SchedulerJournal()
        time.start()
        let sleeper = Task {
            defer { journal.append("sleep-ended") }
            try await clock.sleep(until: .init(offset: .seconds(10)))
        }
        _ = try await source.nextSleep()
        let handle = try registerPendingCapture(on: engine, journal: journal)
        #expect(time.closeAdmission() == nil)
        engine.stop()
        #expect(handle.registration.phase == .canceled)
        #expect(handle.registration.engine == nil)
        // Also exercise a cancellation caller that fetched its engine before stop.
        #expect(!engine.cancel(handle.registration))
        _ = try await source.nextCancellation()
        #expect(journal.values.isEmpty)
        #expect(source.activeWaits == 0)
        await engine.drain()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(journal.values.sorted() == ["disposed", "sleep-ended"])
        time.close()
    }

    @Test(arguments: [false, true], [false, true])
    func `finish joins direct canceled capture disposal despite canceled waiters`(
        alreadyCanceled: Bool, failClock: Bool) async throws
    {
        let clock = SchedulerTestClock()
        let stopping = SchedulerJournal()
        let (execution, systems) = try await SchedulerFixtures.setup(clock: clock.source) {
            stopping.append("stopping")
        }
        let entered = SchedulerJournal()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let handle = try registerMarker(on: systems[0].scheduling, reporter: execution.reporter) {
            entered.append("disposing")
            #expect(release.wait(timeout: .now() + 10) == .success)
        }
        _ = try await clock.nextSleep()
        let canceled = Task { await cancelOnDispatchQueue(handle) }
        #expect(await entered.take(1) == ["disposing"])
        let stopped = SchedulerJournal()
        _ = try SchedulerFixtures.pendingProbe(on: systems[0].scheduling, after: .seconds(20), journal: stopped)
        if failClock {
            _ = try await clock.nextCancellation()
            #expect(try await clock.nextSleep().deadline == .seconds(20))
            clock.advance(to: .seconds(-1), early: true)
            // Failure ends the worker before finish owns shutdown.
            #expect(await stopped.take(1) == ["discarded"])
        }
        let finish = Task {
            if alreadyCanceled {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return await execution.finish()
        }
        if !failClock {
            #expect(await stopped.take(1) == ["discarded"])
            _ = try await clock.nextCancellation()
        }
        #expect(await stopping.take(1) == ["stopping"])
        finish.cancel()
        let repeated = Task { await execution.finish() }
        repeated.cancel()
        #expect(execution.reporter.report == nil)
        #expect(handle.registration.phase == .canceled)
        #expect(handle.registration.engine == nil)
        #expect(!handle.cancel())
        release.signal()
        #expect(await canceled.value)
        let result = await finish.value
        assertDisposed(result, reporter: execution.reporter, failClock: failClock)
        #expect(await repeated.value.report == result.report)
        #expect(clock.activeWaits == 0)
    }

    @Test(arguments: [false, true])
    func `deferred cancellation releases captures before completing disposal accounting`(closeAdmission: Bool)
        async throws
    {
        let (execution, systems) = try await SchedulerFixtures.setup()
        let actions = PostUnlockActions()
        let protected = Mutex(false)
        let released = Mutex(false)
        let handle = try registerMarker(on: systems[0].scheduling, reporter: execution.reporter) {
            #expect(protected.withLock { $0 })
            released.withLock { $0 = true }
        }
        if closeAdmission {
            // Finish can close common admission before the engine receives stop.
            #expect(systems[0].time.closeAdmission() == nil)
        }
        PostUnlockActions.$current.withValue(actions) {
            protected.withLock { committed in
                #expect(handle.cancel())
                #expect(!released.withLock { $0 })
                committed = true
            }
        }
        actions.drain()
        #expect(released.withLock { $0 })
        let result = await execution.finish()
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.system(DiagnosticLabel("canceled-capture"))])
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
        #expect(!handle.cancel())
    }

    @Test
    func `consumer retained captures do not extend scheduler disposal`() async throws {
        let (execution, systems) = try await SchedulerFixtures.setup()
        let reporter = execution.reporter
        var retained: SchedulerReleaseMarker? = SchedulerReleaseMarker {
            reporter.record(Diagnostic(issue: .system(DiagnosticLabel("consumer-release"))))
        }
        let handle = try systems[0].scheduling.schedule(
            at: .seconds(10), for: SchedulerFixtures.record())
        { [retained] in
            withExtendedLifetime(retained) { _ = Issue.record("Canceled delivery must not run") }
        }
        #expect(handle.cancel())
        let result = await execution.finish()
        #expect(result.report.recordingHealth.isHealthy)
        #expect(result.report.diagnostics.isEmpty)
        retained = nil
        #expect(reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [
            .system(DiagnosticLabel("consumer-release")),
        ])
        #expect(await execution.finish().report == result.report)
    }

    private func cancelOnDispatchQueue(_ handle: ScheduledItemHandle) async -> Bool {
        await withCheckedContinuation { continuation in
            // A synchronous destructor blocks a dispatch thread, never the cooperative executor.
            DispatchQueue.global().async { continuation.resume(returning: handle.cancel()) }
        }
    }

    private func assertDisposed(_ result: ScenarioFinalizationResult, reporter: DiagnosticReporter, failClock: Bool) {
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(result.definition == nil)
        let issues: [DiagnosticIssue] = failClock ? [
            .scheduling(.logicalTime(.clockMovedBackward)), .logicalTime(.clockMovedBackward),
            .system(DiagnosticLabel("canceled-capture")),
        ] : [.system(DiagnosticLabel("canceled-capture"))]
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == issues)
        #expect(reporter.postFinishDiagnostics.isEmpty)
    }

    private func registerMarker(on lease: SchedulingLease, reporter: DiagnosticReporter,
                                beforeRelease: @escaping @Sendable () -> Void) throws -> ScheduledItemHandle
    {
        let marker = SchedulerReleaseMarker {
            beforeRelease()
            reporter.record(Diagnostic(issue: .system(DiagnosticLabel("canceled-capture")),
                                       recordingImpact: .invalidatesCandidate))
        }
        return try lease.schedule(at: .seconds(10), for: SchedulerFixtures.record()) {
            withExtendedLifetime(marker) { _ = Issue.record("Canceled delivery must not run") }
        }
    }

    private func registerPendingCapture(on engine: DeadlineEngine, journal: SchedulerJournal)
        throws -> ScheduledItemHandle
    {
        let marker = SchedulerReleaseMarker { journal.append("disposed") }
        return try engine.register(.absolute(.seconds(20)), order: .execution) {
            withExtendedLifetime(marker) { _ = Issue.record("Pending delivery must not run") }
        }
    }
}
