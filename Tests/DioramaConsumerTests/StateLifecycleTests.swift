import DioramaCore
import Synchronization
import Testing

struct StateLifecycleTests {
    @Test(arguments: [ScenarioMode.record, .replay, .passthrough], ["state", "dependency", "published"])
    func `every returned milestone retains its cleanup obligation including a nil dependency`(
        mode: ScenarioMode, milestone: String) async throws
    {
        let journal = ResourceJournal()
        let model = MilestoneDefinition(journal: journal, cancelAt: milestone)
        let system = try ScenarioSystem(named: "one", definition: model)
        let startup = Task {
            try await start([AnyScenarioSystem(system)], attachments: [system.attachment], mode: mode)
        }
        if milestone == "published" {
            let execution = try await startup.value
            #expect(try execution.dependency(system) == nil)
            #expect(await (execution.finish()).cleanup.map(\.disposition) == [.completed])
        } else {
            do {
                _ = try await startup.value
                Issue.record("Canceled construction published")
            } catch let failure as ScenarioStartupFailure {
                #expect(failure.cleanup.map(\.disposition) == [.completed])
                #expect(failure.report.diagnostics.map(\.diagnostic.issue) == [.lifecycle(.startupCanceled)])
            }
        }
        let presence = milestone == "state" ? "state" : "dependency"
        #expect(journal.values.contains("stop-one-" + presence))
        #expect(journal.values.contains("cleanup-one-" + presence))
        #expect(journal.values.last == "release-one")
    }

    @Test(arguments: [ScenarioMode.record, .replay, .passthrough], [false, true])
    func `rollback stops every returned state before cleanup and continues after failure`(
        mode: ScenarioMode, failDependency: Bool) async throws
    {
        let journal = ResourceJournal()
        let first = try ScenarioSystem(named: "first", definition: MilestoneDefinition(journal: journal))
        let second = try ScenarioSystem(named: "second", definition: MilestoneDefinition(
            journal: journal, failDependency: failDependency, failCleanup: true))
        let third = try ScenarioSystem(named: "third",
                                       definition: MilestoneDefinition(journal: journal, failState: true))
        do {
            _ = try await start([AnyScenarioSystem(first), AnyScenarioSystem(second), AnyScenarioSystem(third)],
                                attachments: [first.attachment, second.attachment, third.attachment], mode: mode)
            Issue.record("Failed construction published")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.cleanup.map(\.disposition) == [.completed, .failed])
            #expect(failure.report.diagnostics.map(\.diagnostic.issue).contains(.lifecycle(.cleanupFailed)))
        }
        let presence = failDependency ? "state" : "dependency"
        #expect(journal.values.filter { $0.hasPrefix("stop-") || $0.hasPrefix("cleanup-") } == [
            "stop-second-" + presence, "stop-first-dependency",
            "cleanup-second-" + presence, "cleanup-first-dependency",
        ])
    }

    @Test(arguments: [ScenarioMode.record, .replay, .passthrough], [false, true])
    func `cancellation waits for dependency construction to settle before state shutdown`(
        mode: ScenarioMode, fails: Bool) async throws
    {
        let journal = ResourceJournal()
        let gate = ResourceGate()
        defer { gate.release() }
        let system = try ScenarioSystem(named: "one", definition: MilestoneDefinition(
            journal: journal, dependencyGate: gate, failDependency: fails))
        let startup = Task {
            try await start([AnyScenarioSystem(system)], attachments: [system.attachment], mode: mode)
        }
        await gate.waitForEntry()
        startup.cancel()
        #expect(!journal.values.contains { $0.hasPrefix("stop-") })
        gate.release()
        await #expect(throws: ScenarioStartupFailure.self) { try await startup.value }
        let presence = fails ? "state" : "dependency"
        #expect(journal.values.contains("stop-one-" + presence))
        #expect(journal.values.last == "release-one")
    }

    @Test
    func `lifecycle views expire between hooks and cleanup updates reach record freeze`() async throws {
        let views = LifecycleViews()
        let system = try ScenarioSystem(named: "freeze", definition: FreezeDefinition(views: views))
        let execution = try await start([AnyScenarioSystem(system)], attachments: [system.attachment], mode: .record)
        let runtime = try execution.dependency(system)
        try runtime.state.withLock { state, operation in
            try operation.beginRecord(on: state.values, preparation: .init(), capturing: { _ in () },
                                      freeze: { state, _ in state.value })
        }
        let result = await execution.finish()
        let track = try #require(try result.definition?.attachments.first?.track(
            system.attachment.trackIDs[0], as: Int.self, header: Void.self))
        #expect(track.records.map(\.value) == [42])
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.lifecycle(.lifecycleContextClosed)])
        let access = try #require(views.values.withLock { $0.last })
        #expect(throws: SequentialOperationFailure.self) { try access.withLock { $0.value = 99 } }
        #expect(runtime.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.lifecycleContextClosed)])
        #expect(result.report == runtime.reporter.report)
    }

    @Test(arguments: [false, true])
    func `tracked synchronous and asynchronous throwing bodies release admission`(asynchronous: Bool) async throws {
        let model = ResourceDefinition(journal: ResourceJournal(), weak: ResourceWeakBox())
        let (execution, runtime) = try await startResource(model)
        if asynchronous {
            await #expect(throws: ResourceTestFailure.self) {
                try await runtime.state.withTrackedValue(\.first) { _ async throws in
                    await Task.yield()
                    throw ResourceTestFailure.expected
                }
            }
        } else {
            #expect(throws: ResourceTestFailure.self) {
                try runtime.state.withTrackedValue(\.first) { _ in throw ResourceTestFailure.expected }
            }
        }
        #expect(await (execution.finish()).report.diagnostics.isEmpty)
    }

    @Test
    func `partial activation drains only after earlier attachments can stop its work`() async throws {
        let journal = ResourceJournal()
        let work = ResourceGate()
        defer { work.release() }
        let first = try ScenarioSystem(named: "first", definition: MilestoneDefinition(
            journal: journal, stopGate: work))
        let second = try ScenarioSystem(named: "second", definition: MilestoneDefinition(
            journal: journal, trackedWork: work, failDependency: true))
        await #expect(throws: ScenarioStartupFailure.self) {
            try await start([AnyScenarioSystem(first), AnyScenarioSystem(second)],
                            attachments: [first.attachment, second.attachment], mode: .record)
        }
        let stopped = try #require(journal.values.firstIndex(of: "stop-first-dependency"))
        let drained = try #require(journal.values.firstIndex(of: "tracked-drained"))
        let cleanup = try #require(journal.values.firstIndex(of: "cleanup-second-state"))
        #expect(stopped < drained && drained < cleanup)
    }

    @Test(arguments: [ScenarioMode.record, .replay, .passthrough])
    func `dependency destruction reports outside state protection before final report freeze`(mode: ScenarioMode)
        async throws
    {
        let system = try ScenarioSystem(named: "release", definition: ReleaseDefinition())
        let execution = try await start([AnyScenarioSystem(system)], attachments: [system.attachment], mode: mode)
        let final = await execution.finish()
        #expect(final.report.diagnostics.map(\.diagnostic.issue) == [.system(DiagnosticLabel("dependency-release"))])
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
    }

    @Test
    func `passthrough state has runtime services but cannot access declared tracks`() async throws {
        let model = MilestoneDefinition(journal: ResourceJournal(), checkPassthroughTracks: true)
        let system = try ScenarioSystem(named: "live", definition: model)
        let execution = try await start([AnyScenarioSystem(system)],
                                        attachments: [system.attachment], mode: .passthrough)
        let result = await execution.finish()
        let expected = Array(repeating: DiagnosticIssue.lifecycle(.invalidTrackRequest), count: 2)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == expected)
        #expect(result.usage[0].tracks[0].activity == .passthrough)
    }

    private func start(_ systems: [AnyScenarioSystem], attachments: [ScenarioAttachment], mode: ScenarioMode)
        async throws -> ScenarioExecution
    {
        try await ScenarioExecution.start(definition: ScenarioDefinition(attachments: attachments),
                                          scenarioID: .init(rawValue: "state-lifecycle"),
                                          defaultMode: mode, systems: systems)
    }
}

private struct MilestoneState: Sendable {
    let key: String
    let lifetime: ResourceReleaseWitness
    var task: Task<Void, Never>?
}

private struct MilestoneDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.milestones")
    let journal: ResourceJournal
    var cancelAt = ""
    var dependencyGate: ResourceGate?
    var trackedWork: ResourceGate?
    var stopGate: ResourceGate?
    var checkPassthroughTracks = false
    var failState = false
    var failDependency = false
    var failCleanup = false

    let track = TrackDefinition<Int, Void>("unused")
    var tracks: [AnyTrackDefinition] {
        [track.erased]
    }

    var record: SystemModeDefinition<MilestoneState, Int?> {
        .init(makeState: makeRecordState, makeDependency: makeRecordDependency,
              requestStop: requestStopRecord, cleanUp: cleanUpRecord)
    }

    var replay: SystemModeDefinition<MilestoneState, Int?> {
        .init(makeState: makeReplayState, makeDependency: makeReplayDependency,
              requestStop: requestStopReplay, cleanUp: cleanUpReplay)
    }

    var passthrough: SystemModeDefinition<MilestoneState, Int?> {
        .init(makeState: makePassthroughState, makeDependency: makePassthroughDependency,
              requestStop: requestStopPassthrough, cleanUp: cleanUpPassthrough)
    }

    func makeRecordState(in context: borrowing SystemStateContext) throws -> MilestoneState {
        if failState {
            throw ResourceTestFailure.expected
        }
        let key = context.attachmentID.key.rawValue
        let state = MilestoneState(key: key, lifetime: ResourceReleaseWitness { journal.append("release-" + key) })
        if cancelAt == "state" {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return state
    }

    func makeReplayState(in context: borrowing SystemStateContext) throws -> MilestoneState {
        try makeRecordState(in: context)
    }

    func makePassthroughState(in context: borrowing SystemStateContext) throws -> MilestoneState {
        if checkPassthroughTracks {
            #expect(throws: PreparationFailure.self) { try context.track(track) }
            #expect(throws: PreparationFailure.self) { try context.lease(for: track) }
        }
        return try makeRecordState(in: context)
    }

    func makeRecordDependency(using execution: SystemExecution<MilestoneState>) async throws -> Int? {
        if let trackedWork {
            let task = Task {
                _ = try? await execution.state.withTrackedValueIfOpen(\.key) { _ async in
                    Issue.record("Quiet work entered before publication")
                }
                try? await execution.state.withTrackedValue(\.key) { _ in
                    await trackedWork.suspend()
                    journal.append("tracked-drained")
                }
            }
            try execution.state.withLock { state, _ in state.task = task }
            await trackedWork.waitForEntry()
        }
        await dependencyGate?.suspend()
        if failDependency {
            throw ResourceTestFailure.expected
        }
        if cancelAt == "dependency" {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return nil
    }

    func makeReplayDependency(using execution: SystemExecution<MilestoneState>) async throws -> Int? {
        try await makeRecordDependency(using: execution)
    }

    func makePassthroughDependency(using execution: SystemExecution<MilestoneState>) async throws -> Int? {
        try await makeRecordDependency(using: execution)
    }

    func requestStopRecord(using lifecycle: borrowing SystemLifecycleContext<MilestoneState>, dependency: Int??) {
        #expect(!Task.isCancelled)
        let key = (try? lifecycle.state.withLock { $0.key }) ?? "missing"
        journal.append("stop-" + key + (dependency == nil ? "-state" : "-dependency"))
        stopGate?.release()
    }

    func cleanUpRecord(using lifecycle: borrowing SystemLifecycleContext<MilestoneState>,
                       dependency: Int??) async -> SystemCleanupResult
    {
        let key = (try? lifecycle.state.withLock { $0.key }) ?? "missing"
        let task = try? lifecycle.state.withLock { $0.task }
        await task?.value
        journal.append("cleanup-" + key + (dependency == nil ? "-state" : "-dependency"))
        return failCleanup ? .failed(DiagnosticLabel("ancillary")) : .completed
    }

    func requestStopReplay(using lifecycle: borrowing SystemLifecycleContext<MilestoneState>, dependency: Int??) {
        requestStopRecord(using: lifecycle, dependency: dependency)
    }

    func cleanUpReplay(using lifecycle: borrowing SystemLifecycleContext<MilestoneState>,
                       dependency: Int??) async -> SystemCleanupResult
    {
        await cleanUpRecord(using: lifecycle, dependency: dependency)
    }

    func requestStopPassthrough(using lifecycle: borrowing SystemLifecycleContext<MilestoneState>, dependency: Int??) {
        requestStopRecord(using: lifecycle, dependency: dependency)
    }

    func cleanUpPassthrough(using lifecycle: borrowing SystemLifecycleContext<MilestoneState>,
                            dependency: Int??) async -> SystemCleanupResult
    {
        await cleanUpRecord(using: lifecycle, dependency: dependency)
    }
}

private struct FreezeState: Sendable {
    let values: HeaderlessSequentialTrackLease<Int>
    var value = 1
}

private struct FreezeDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.cleanup-freeze")
    let values = TrackDefinition<Int, Void>("values")
    let views: LifecycleViews
    var tracks: [AnyTrackDefinition] {
        [values.erased]
    }

    var record: SystemModeDefinition<FreezeState, SystemExecution<FreezeState>> {
        .init(makeState: makeRecordState, makeDependency: makeRecordDependency,
              requestStop: requestStopRecord, cleanUp: cleanUpRecord)
    }

    var replay: SystemModeDefinition<FreezeState, SystemExecution<FreezeState>> {
        .init(makeState: makeReplayState, makeDependency: makeReplayDependency)
    }

    var passthrough: SystemModeDefinition<Void, SystemExecution<FreezeState>> {
        .init(makeDependency: makePassthroughDependency)
    }

    func makeRecordState(in context: borrowing SystemStateContext) throws -> FreezeState {
        try FreezeState(values: context.lease(for: values))
    }

    func makeReplayState(in context: borrowing SystemStateContext) throws -> FreezeState {
        try makeRecordState(in: context)
    }

    func makeRecordDependency(using execution: SystemExecution<FreezeState>) -> SystemExecution<FreezeState> {
        execution
    }

    func makeReplayDependency(using execution: SystemExecution<FreezeState>) -> SystemExecution<FreezeState> {
        execution
    }

    func makePassthroughDependency(using _: SystemExecution<Void>) throws -> SystemExecution<FreezeState> {
        throw ResourceTestFailure.expected
    }

    func requestStopRecord(using lifecycle: borrowing SystemLifecycleContext<FreezeState>,
                           dependency _: SystemExecution<FreezeState>?)
    {
        views.values.withLock { $0.append(lifecycle.state) }
    }

    func cleanUpRecord(using lifecycle: borrowing SystemLifecycleContext<FreezeState>,
                       dependency _: SystemExecution<FreezeState>?) -> SystemCleanupResult
    {
        let expired = views.values.withLock { $0[0] }
        #expect(throws: SequentialOperationFailure.self) { try expired.withLock { $0.value = -1 } }
        _ = try? lifecycle.state.withLock { $0.value = 42 }
        views.values.withLock { $0.append(lifecycle.state) }
        return .completed
    }
}

private final class LifecycleViews: Sendable {
    let values = Mutex<[SystemLifecycleStateAccess<FreezeState>]>([])
}

private struct ReleaseDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.dependency-release")
    var record: SystemModeDefinition<Void, ResourceReleaseWitness> {
        .init(makeState: makeRecordState, makeDependency: makeRecordDependency)
    }

    var replay: SystemModeDefinition<Void, ResourceReleaseWitness> {
        .init(makeState: makeReplayState, makeDependency: makeReplayDependency)
    }

    var passthrough: SystemModeDefinition<Void, ResourceReleaseWitness> {
        .init(makeDependency: makePassthroughDependency)
    }

    func makeRecordState(in _: borrowing SystemStateContext) {}
    func makeReplayState(in _: borrowing SystemStateContext) {}
    func makeRecordDependency(using execution: SystemExecution<Void>) -> ResourceReleaseWitness {
        ResourceReleaseWitness {
            execution.reporter.record(Diagnostic(issue: .system(DiagnosticLabel("dependency-release"))))
            _ = try? execution.state.withLockIfOpen { _, _ in Issue.record("Release reopened state") }
        }
    }

    func makeReplayDependency(using execution: SystemExecution<Void>) -> ResourceReleaseWitness {
        makeRecordDependency(using: execution)
    }

    func makePassthroughDependency(using execution: SystemExecution<Void>) -> ResourceReleaseWitness {
        makeRecordDependency(using: execution)
    }
}
