import DioramaCore
import Testing

private struct ReplayLeaseDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.replay-lease")
    let values: TrackDefinition<Int, Void>

    init(policy: ReplayContinuationPolicy<Int>, values: [Int] = []) throws {
        self.values = try TrackDefinition(
            "values", values: values.map { try ValuePreparation<Int>().admitPrepared($0) },
            continuationPolicy: policy)
    }

    var tracks: [AnyTrackDefinition] {
        [values.erased]
    }

    func makeRecordState(in context: borrowing SystemStateContext) throws -> HeaderlessSequentialTrackLease<Int> {
        try context.lease(for: values)
    }

    func makeReplayState(in context: borrowing SystemStateContext) throws -> HeaderlessSequentialTrackLease<Int> {
        try context.lease(for: values)
    }

    func makeRecordDependency(using execution: SystemExecution<HeaderlessSequentialTrackLease<Int>>)
        throws -> HeaderlessSequentialTrackLease<Int>
    {
        try execution.withActiveState { values, _ in values }
    }

    func makeReplayDependency(using execution: SystemExecution<HeaderlessSequentialTrackLease<Int>>)
        throws -> HeaderlessSequentialTrackLease<Int>
    {
        try execution.withActiveState { values, _ in values }
    }

    func makePassthroughDependency() throws -> HeaderlessSequentialTrackLease<Int> {
        throw CancellationError()
    }
}

struct ReplayLeaseLifetimeTests {
    @Test func `public replay lease preserves policy after managed state closes`() async throws {
        for policy in [ReplayContinuationPolicy<Int>.replayLast(defaultValue: -1), .fallback(-1), .error] {
            let definition = try ReplayLeaseDefinition(policy: policy, values: [9, 4])
            let system = try ScenarioSystem(named: "values", definition: definition)
            let execution = try start(system)
            let lease = try execution.dependency(system)
            #expect(try lease.consumeNext() == 9)
            let final = await execution.finish()
            switch policy {
            case .error:
                #expect(throws: SequentialOperationFailure.self) { try lease.consumeNext() }
            case .fallback:
                #expect(try lease.consumeNext() == -1)
            case .replayLast:
                #expect(try lease.consumeNext() == 9)
            }
            #expect(final.usage[0].tracks[0].unclaimedRecords.count == 1)
            #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
            #expect(await execution.finish().report == final.report)
        }
    }

    @Test func `direct replay exhaustion appears only in the completed report`() async throws {
        let system = try ScenarioSystem(named: "values", definition: ReplayLeaseDefinition(policy: .fallback(-1)))
        let execution = try start(system)
        let lease = try execution.dependency(system)
        #expect(try lease.consumeNext() == -1)
        #expect(execution.reporter.report == nil)
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.sequential(.replayExhausted(availableCount: 0))])
        #expect(execution.reporter.report == result.report)
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
        #expect(try lease.consumeNext() == -1)
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
        #expect(await execution.finish().report == result.report)
    }

    private func start(_ system: ScenarioSystem<HeaderlessSequentialTrackLease<Int>>)
        throws -> ScenarioExecution
    {
        try ScenarioExecution.start(definition: ScenarioDefinition(attachments: [system.attachment]),
                                    scenarioID: .init(rawValue: "replay-lease"), defaultMode: .replay,
                                    systems: [AnyScenarioSystem(system)])
    }
}
