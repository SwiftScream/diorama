import DioramaCore
import Dispatch
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SchedulerStopOrderingTests {
    @Test(arguments: [ScenarioMode.record, .replay, .passthrough])
    func `every stop hook precedes pending capture disposal despite canceled finish waiters`(mode: ScenarioMode)
        async throws
    {
        let journal = ResourceJournal()
        let stopSignal = DispatchSemaphore(value: 0)
        let stopGate = ResourceGate()
        defer { stopGate.release() }
        let model = SchedulerStopDefinition(journal: journal, stopSignal: stopSignal, stopGate: stopGate)
        let first = try ScenarioSystem(named: "first", definition: model)
        let second = try ScenarioSystem(named: "second", definition: model)
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [first.attachment, second.attachment]),
            scenarioID: ScenarioID(rawValue: "scheduler-stop"), defaultMode: mode,
            systems: [AnyScenarioSystem(first), AnyScenarioSystem(second)])
        let handle = try registerCapture(on: execution.dependency(second), record: RecordIdentity(
            trackID: second.attachment.trackIDs[0], sequence: 0), journal: journal, stopSignal: stopSignal)
        let finish = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await execution.finish()
        }
        await stopGate.waitForEntry()
        #expect(journal.values == ["stop-second", "stop-first"])
        #expect(!handle.cancel())
        #expect(execution.reporter.report == nil)
        let concurrent = Task { await execution.finish() }
        concurrent.cancel()
        finish.cancel()
        stopGate.release()
        let result = await finish.value
        #expect(journal.values == [
            "stop-second", "stop-first", "dispose", "disposed", "cleanup-second", "cleanup-first",
        ])
        #expect(result.cleanup.map(\.disposition) == [.completed, .completed])
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.system(DiagnosticLabel("capture-release"))])
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
        #expect(await concurrent.value.report == result.report)
        #expect(await execution.finish().report == result.report)
        #expect(!handle.cancel())
    }

    private func registerCapture(on runtime: SystemExecution<String>, record: RecordIdentity,
                                 journal: ResourceJournal, stopSignal: DispatchSemaphore) throws -> ScheduledItemHandle
    {
        let reporter = runtime.reporter
        let capture = ResourceReleaseWitness {
            journal.append("dispose")
            // Only an emergency escape bounds failure on the old implementation.
            // Success requires the stop signal, never elapsed time.
            #expect(stopSignal.wait(timeout: .now() + 2) == .success)
            journal.append("disposed")
            reporter.record(Diagnostic(issue: .system(DiagnosticLabel("capture-release")),
                                       recordingImpact: .invalidatesCandidate))
        }
        return try runtime.scheduling.schedule(after: .seconds(60), for: record) {
            withExtendedLifetime(capture) { _ = Issue.record("Pending delivery must be canceled") }
        }
    }
}

private struct SchedulerStopDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.scheduler-stop")
    let journal: ResourceJournal
    let stopSignal: DispatchSemaphore
    let stopGate: ResourceGate
    let values = TrackDefinition<Int, Void>("values")

    var tracks: [AnyTrackDefinition] {
        [values.erased]
    }

    func makeRecordState(in context: borrowing SystemStateContext) -> String {
        context.attachmentID.key.rawValue
    }

    func makeReplayState(in context: borrowing SystemStateContext) -> String {
        makeRecordState(in: context)
    }

    func makePassthroughState(in context: borrowing SystemStateContext) -> String {
        makeRecordState(in: context)
    }

    func makeRecordDependency(using execution: SystemExecution<String>) -> SystemExecution<String> {
        execution
    }

    func makeReplayDependency(using execution: SystemExecution<String>) -> SystemExecution<String> {
        execution
    }

    func makePassthroughDependency(using execution: SystemExecution<String>) -> SystemExecution<String> {
        execution
    }

    func requestStopRecord(using lifecycle: borrowing SystemLifecycleContext<String>,
                           dependency _: SystemExecution<String>?) async
    {
        guard let key = try? lifecycle.state.withLock({ $0 }) else { return }
        journal.append("stop-" + key)
        if key == "first" {
            stopSignal.signal()
            await stopGate.suspend()
        }
    }

    func requestStopReplay(using lifecycle: borrowing SystemLifecycleContext<String>,
                           dependency: SystemExecution<String>?) async
    {
        await requestStopRecord(using: lifecycle, dependency: dependency)
    }

    func requestStopPassthrough(using lifecycle: borrowing SystemLifecycleContext<String>,
                                dependency: SystemExecution<String>?) async
    {
        await requestStopRecord(using: lifecycle, dependency: dependency)
    }

    func cleanUpRecord(using lifecycle: borrowing SystemLifecycleContext<String>,
                       dependency _: SystemExecution<String>?) -> SystemCleanupResult
    {
        if let key = try? lifecycle.state.withLock({ $0 }) {
            journal.append("cleanup-" + key)
        }
        return .completed
    }

    func cleanUpReplay(using lifecycle: borrowing SystemLifecycleContext<String>,
                       dependency: SystemExecution<String>?) -> SystemCleanupResult
    {
        cleanUpRecord(using: lifecycle, dependency: dependency)
    }

    func cleanUpPassthrough(using lifecycle: borrowing SystemLifecycleContext<String>,
                            dependency: SystemExecution<String>?) -> SystemCleanupResult
    {
        cleanUpRecord(using: lifecycle, dependency: dependency)
    }
}
