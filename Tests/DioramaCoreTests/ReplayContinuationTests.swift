import DioramaCore
import Testing

struct ReplayContinuationTests {
    @Test(arguments: [ReplayContinuationPolicy<Int>.fallback(-1), .replayLast(defaultValue: -1)])
    func `empty replay continues without inventing records`(_ policy: ReplayContinuationPolicy<Int>) async throws {
        let (execution, lease) = try ReplayContinuationFixtures.start(values: [], policy: policy)
        #expect(try lease.consumeNext() == -1)
        #expect(try lease.consumeNext() == -1)
        let result = await execution.finish()
        let usage = result.usage[0].tracks[0]
        #expect(usage.activity == .replay(claimedCount: 0, unclaimedCount: 0))
        #expect(usage.claimedRecords.isEmpty)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.replayExhausted(availableCount: 0)),
            .sequential(.replayExhausted(availableCount: 0)),
        ])
        #expect(result.report.diagnostics.map(\.diagnostic.context.recordIdentity?.sequence) == [0, 1])
        #expect(try lease.consumeNext() == -1)
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
        #expect(await execution.finish().report == result.report)
        #expect(await execution.finish().usage == result.usage)
    }

    @Test
    func `constant fallback never becomes the last recorded value`() async throws {
        let (execution, lease) = try ReplayContinuationFixtures.start(values: [9, 4], policy: .fallback(-1))
        #expect(try lease.consumeNext() == 9)
        #expect(try lease.consumeNext() == 4)
        #expect(try lease.consumeNext() == -1)
        let result = await execution.finish()
        #expect(result.usage[0].tracks[0].claimedRecords.count == 2)
        #expect(!result.usage[0].tracks[0].claimedRecords.contains { !$0.isConsumed })
        #expect(try lease.consumeNext() == -1)
    }

    @Test
    func `replay last follows consumption order including backward values`() async throws {
        let (execution, lease) = try ReplayContinuationFixtures.start(
            values: [9, 9, 4], policy: .replayLast(defaultValue: -1))
        #expect(try (0..<5).map { _ in try lease.consumeNext() } == [9, 9, 4, 4, 4])
        let result = await execution.finish()
        #expect(result.usage[0].tracks[0].activity == .replay(claimedCount: 3, unclaimedCount: 0))
        #expect(result.report.diagnostics.count == 2)
        #expect(try lease.consumeNext() == 4)
    }

    @Test(arguments: [false, true])
    func `closing a partially read track preserves only its consumed continuation`(_ consume: Bool) async throws {
        let (execution, lease) = try ReplayContinuationFixtures.start(
            values: [9, 4], policy: .replayLast(defaultValue: -1))
        if consume {
            #expect(try lease.consumeNext() == 9)
        }
        let result = await execution.finish()
        #expect(try lease.consumeNext() == (consume ? 9 : -1))
        #expect(result.usage[0].tracks[0].unclaimedRecords.count == (consume ? 1 : 2))
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
        #expect(await execution.finish().report == result.report)
        #expect(await execution.finish().usage == result.usage)
    }

    @Test(arguments: [ScenarioMode.record, .passthrough])
    func `continuation cannot make wrong mode reads succeed`(_ mode: ScenarioMode) async throws {
        let (execution, lease) = try ReplayContinuationFixtures.start(
            values: [9], policy: .fallback(-1), mode: mode)
        #expect(throws: SequentialOperationFailure.self) { try lease.consumeNext() }
        let result = await execution.finish()
        #expect(result.report.diagnostics.first?.diagnostic.issue ==
            .sequential(.wrongMode(expected: .replay, actual: mode)))
        #expect(throws: SequentialOperationFailure.self) { try lease.consumeNext() }
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
    }

    @Test
    func `explicit claims neither use nor update synchronous continuation`() async throws {
        let (execution, lease) = try ReplayContinuationFixtures.start(
            values: [9, 4], policy: .replayLast(defaultValue: -1))
        #expect(try lease.consumeNext() == 9)
        let claim = try lease.claim(matching: (), using: .sequential())
        #expect(claim.record.value == 4)
        #expect(claim.markConsumed())
        #expect(try lease.consumeNext() == 9)
        #expect(throws: SequentialOperationFailure.self) { try lease.claim(matching: (), using: .sequential()) }
        let result = await execution.finish()
        #expect(result.usage[0].tracks[0].claimedRecords.count == 2)
        #expect(result.report.diagnostics.count == 2)
    }

    @Test
    func `consumption and continuation preserve stored authorship`() async throws {
        let trackID = ExecutionFixtures.track("authorship")
        let values: [OverridableValue<Int>] = [.observed(9), .override(4)]
        let track = try SequentialTrack(id: trackID, values: preparedValues(values))
        let attachment = try ScenarioAttachment(id: trackID.attachmentID).adding(track)
        let system = try ScenarioSystem(type: ExecutionFixtures.type, attachment: attachment) { context in
            let lease = try context.lease(
                for: trackID, preparation: ValuePreparation<OverridableValue<Int>>(),
                continuationPolicy: .replayLast(defaultValue: .observed(-1)))
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let execution = try ReplayContinuationFixtures.start(system)
        let lease = try execution.dependency(system)
        #expect(try (0..<3).map { _ in try lease.consumeNext() } == [.observed(9), .override(4), .override(4)])
        let result = await execution.finish()
        let definition = try #require(result.definition)
        let stored = try definition.attachments[0].track(trackID, as: OverridableValue<Int>.self)
        #expect(stored?.records.map(\.value) == values)
        #expect(try lease.consumeNext() == .override(4))
    }

    @Test
    func `typed headers remain independent of replay and continuation`() async throws {
        let trackID = ExecutionFixtures.track("header")
        let header = try ValuePreparation<String>().admitPrepared("origin", context: .track(trackID))
        let track = try SequentialTrack(id: trackID, header: header, values: preparedValues(["first"]))
        let attachment = try ScenarioAttachment(id: trackID.attachmentID).adding(track)
        let system = try ScenarioSystem(type: ExecutionFixtures.type, attachment: attachment) { context in
            let lease = try context.lease(
                for: trackID, preparation: ValuePreparation<String>(), headerPreparation: ValuePreparation<String>(),
                continuationPolicy: .fallback("fallback"))
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let execution = try ReplayContinuationFixtures.start(system)
        let lease = try execution.dependency(system)
        #expect(lease.baselineHeader() == "origin")
        #expect(try lease.consumeNext() == "first")
        #expect(try lease.consumeNext() == "fallback")
        _ = await execution.finish()
        #expect(lease.baselineHeader() == nil)
        #expect(try lease.consumeNext() == "fallback")
    }
}

enum ReplayContinuationFixtures {
    static func start(
        values: [Int], policy: ReplayContinuationPolicy<Int>, mode: ScenarioMode = .replay,
        sink: DiagnosticSink? = nil) throws -> (ScenarioExecution, HeaderlessSequentialTrackLease<Int>)
    {
        let trackID = ExecutionFixtures.track("continuation")
        let track = try SequentialTrack(id: trackID, values: preparedValues(values))
        let attachment = try ScenarioAttachment(id: trackID.attachmentID).adding(track)
        let system = try ScenarioSystem(type: ExecutionFixtures.type, attachment: attachment) { context in
            let lease = try context.lease(
                for: trackID, preparation: ValuePreparation<Int>(), continuationPolicy: policy)
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let execution = try start(system, mode: mode, sink: sink)
        return try (execution, execution.dependency(system))
    }

    static func start(_ system: ScenarioSystem<some Any>, mode: ScenarioMode = .replay,
                      sink: DiagnosticSink? = nil) throws -> ScenarioExecution
    {
        try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]),
            scenarioID: ScenarioID(rawValue: "continuation"), defaultMode: mode,
            systems: [AnyScenarioSystem(system)], sink: sink)
    }
}
