import Diorama
import DioramaCore
import Testing

struct ResourceActorTests {
    @Test
    func `instance actor hooks stop and join resource owned asynchronous work`() async throws {
        let journal = ResourceJournal()
        let gate = ResourceGate()
        defer { gate.release() }
        let system = try ScenarioSystem(named: "worker", definition: WorkerDefinition(journal: journal, gate: gate))
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]), scenarioID: .init(rawValue: "worker"),
            defaultMode: .record, systems: [AnyScenarioSystem(system)])
        let systemExecution = try execution.dependency(system)
        #expect(try systemExecution.state.withTrackedValue(\.worker) { $0.identifier() } == 42)
        #expect(try await systemExecution.state.withTrackedValue(\.worker) { await $0.isRunning() })
        await gate.waitForEntry()
        let final = await execution.finish()
        #expect(journal.values == ["worker-stopped", "worker-done", "worker-ended"])
        #expect(final.report.diagnostics.isEmpty)
    }

    @Test
    func `consumer admission covers suspended construction and cleanup and retains body failure reports`()
        async throws
    {
        let construction = ResourceGate()
        let cleanup = ResourceGate()
        defer { construction.release(); cleanup.release() }
        let model = ResourceDefinition(journal: ResourceJournal(), weak: ResourceWeakBox(),
                                       construction: construction, cleanup: cleanup)
        let system = try ScenarioSystem(named: "native", definition: model)
        let setup = try Diorama(scenarioID: "consumer", mode: .record, systems: system)
        let first = Task {
            try await setup.execute { _, _ in throw ResourceTestFailure.expected }
        }
        await construction.waitForEntry()
        #expect(setup.report == nil)
        await #expect(throws: DioramaExecutionError.executionAlreadyInProgress) {
            try await setup.execute { _, _ in () }
        }
        construction.release()
        await cleanup.waitForEntry()
        #expect(setup.report == nil)
        await #expect(throws: DioramaExecutionError.executionAlreadyInProgress) {
            try await setup.execute { _, _ in () }
        }
        first.cancel()
        cleanup.release()
        await #expect(throws: ResourceTestFailure.self) { try await first.value }
        #expect(setup.report != nil)
        let next = try await setup.execute { _, systemExecution in
            try systemExecution.state.withLock { state, _ in state.observations }
        }
        #expect(next.body == 0)
        #expect(setup.report != nil)
    }
}

private actor ResourceWorker {
    let journal: ResourceJournal
    let gate: ResourceGate
    private var task: Task<Void, Never>?
    private var stopped = false

    init(journal: ResourceJournal, gate: ResourceGate) {
        self.journal = journal; self.gate = gate
    }

    nonisolated func identifier() -> Int {
        42
    }

    func isRunning() -> Bool {
        !stopped
    }

    func start() {
        let gate = gate
        let journal = journal
        task = Task { await gate.suspend(); journal.append("worker-done") }
    }

    func stop() {
        stopped = true
        journal.append("worker-stopped")
        task?.cancel()
        gate.release()
    }

    func end() async -> SystemCleanupResult {
        await task?.value
        task = nil
        journal.append("worker-ended")
        return .completed
    }
}

private struct WorkerState: Sendable { let worker: ResourceWorker }

private struct WorkerDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.worker")
    let journal: ResourceJournal
    let gate: ResourceGate
    func makeRecordState(in _: borrowing SystemStateContext) async -> WorkerState {
        let worker = ResourceWorker(journal: journal, gate: gate)
        await worker.start()
        return WorkerState(worker: worker)
    }

    func makeReplayState(in context: borrowing SystemStateContext) async
        -> WorkerState
    {
        await makeRecordState(in: context)
    }

    func makeRecordDependency(using systemExecution: SystemExecution<WorkerState>)
        -> SystemExecution<WorkerState>
    {
        systemExecution
    }

    func makeReplayDependency(using systemExecution: SystemExecution<WorkerState>)
        -> SystemExecution<WorkerState>
    {
        systemExecution
    }

    func requestStopRecord(using lifecycle: borrowing SystemLifecycleContext<WorkerState>,
                           dependency _: SystemExecution<WorkerState>?) async
    {
        let worker = try? lifecycle.state.withLock { $0.worker }
        await worker?.stop()
    }

    func cleanUpRecord(using lifecycle: borrowing SystemLifecycleContext<WorkerState>,
                       dependency _: SystemExecution<WorkerState>?) async -> SystemCleanupResult
    {
        let worker = try? lifecycle.state.withLock { $0.worker }
        return await worker?.end() ?? .completed
    }

    func makePassthroughDependency(using _: SystemExecution<Void>) throws -> SystemExecution<WorkerState> {
        throw ResourceTestFailure.expected
    }
}
