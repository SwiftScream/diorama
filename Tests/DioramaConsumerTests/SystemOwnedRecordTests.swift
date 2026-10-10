import DioramaCore
import Testing

/// A small HTTP-shaped ownership proof, not the production HTTP schema.
private struct ConsumerOperation: Equatable, Sendable {
    indirect enum Path: Equatable, Sendable {
        case challenge(status: Int, continuationDelay: Duration, retry: Path)
        case response(status: Int, prefix: [UInt8], outcome: BodyOutcome)
        case open
    }

    enum BodyOutcome: Equatable, Sendable {
        case returned
        case failed(code: Int)
        case open
    }

    let request: String
    let path: Path
}

private struct ConsumerOperationState: Sendable {
    let records: HeaderlessSequentialTrackLease<ConsumerOperation>
    var drafts: [RecordIdentity: ConsumerOperation] = [:]
}

private struct ConsumerOperationDraft: Sendable {
    let runtime: SystemRuntime<ConsumerOperationState>
    let identity: RecordIdentity

    func observe(_ path: PreparedValue<ConsumerOperation.Path>) -> Bool {
        guard !runtime.isClosed else { return false }
        return (try? runtime.withActiveState { state, _ in
            guard let current = state.drafts[identity] else { return false }
            state.drafts[identity] = ConsumerOperation(request: current.request, path: path.value)
            return true
        }) ?? false
    }
}

private struct OperationDependency: Sendable {
    let runtime: SystemRuntime<ConsumerOperationState>
    var reporter: DiagnosticReporter {
        runtime.reporter
    }

    func begin(input: String) throws -> ConsumerOperationDraft {
        let identity = try runtime.withActiveState { state, operation in
            try operation.beginRecord(
                on: state.records, preparation: ValuePreparation<ConsumerOperation>(),
                capturing: { identity in
                    let prepared = try ValuePreparation<String>().prepare(
                        capturing: { input }, purpose: .recording, reporter: reporter, context: .record(identity))
                    state.drafts[identity] = ConsumerOperation(request: prepared.value, path: .open)
                    return identity
                }, freeze: { state, identity in state.drafts.removeValue(forKey: identity) })
        }
        return ConsumerOperationDraft(runtime: runtime, identity: identity)
    }

    func claim(matching input: String, using selector: ReplaySelector<String, ConsumerOperation>) throws
        -> ReplayClaim<ConsumerOperation>
    {
        try runtime.withActiveState { state, operation in
            try operation.claim(on: state.records, matching: input, using: selector)
        }
    }
}

private struct OperationDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.operations")
    let records = SystemTrack<ConsumerOperation, Void>("operations")
    var tracks: [AnySystemTrack] {
        [records.erased]
    }

    func makeRecordState(in context: borrowing SystemStateContext) throws -> ConsumerOperationState {
        try ConsumerOperationState(records: context.lease(for: records))
    }

    func makeReplayState(in context: borrowing SystemStateContext) throws -> ConsumerOperationState {
        try makeRecordState(in: context)
    }

    func makeRecordDependency(using runtime: SystemRuntime<ConsumerOperationState>) -> OperationDependency {
        OperationDependency(runtime: runtime)
    }

    func makeReplayDependency(using runtime: SystemRuntime<ConsumerOperationState>) -> OperationDependency {
        OperationDependency(runtime: runtime)
    }

    func makePassthroughDependency() throws -> OperationDependency {
        throw OperationFailure.unsupported
    }
}

private enum OperationFailure: Error { case unsupported }

struct SystemOwnedRecordTests {
    @Test
    func `consumer owns recursive partial and open records across capture and selection`() async throws {
        let system = try ScenarioSystem(named: "one", definition: OperationDefinition())
        let attachment = system.attachment
        let recording = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "domain-records"), defaultMode: .record,
            systems: [AnyScenarioSystem(system)])
        let lease = try recording.dependency(system)
        let draft = try lease.begin(input: "request")
        let path = try preparedPath(reporter: lease.reporter)
        #expect(draft.observe(path))
        _ = try lease.begin(input: "pending")
        let result = await recording.finish()
        let definition = try #require(result.definition)
        #expect(!draft.observe(path))
        let replay = try ScenarioExecution.start(
            definition: definition,
            scenarioID: ScenarioID(rawValue: "domain-records"), defaultMode: .replay,
            systems: [AnyScenarioSystem(system)])
        let replayLease = try replay.dependency(system)
        let selector = ReplaySelector<String, ConsumerOperation>.exactInput(\.request)
        let open = try replayLease.claim(matching: "pending", using: selector)
        let partial = try replayLease.claim(matching: "request", using: selector)
        #expect(open.record.value.path == .open)
        #expect(partial.record.value.path == path.value)
        #expect(open.markConsumed())
        #expect(partial.advance(to: 2))
        #expect(partial.markConsumed())
        let replayResult = await replay.finish()
        #expect(replayResult.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(replayResult.evaluate(.allClaimedRecordsConsumed).isSatisfied)
    }

    private func preparedPath(reporter: DiagnosticReporter) throws -> PreparedValue<ConsumerOperation.Path> {
        try ValuePreparation<ConsumerOperation.Path>().prepare(capturing: {
            .challenge(status: 401, continuationDelay: .milliseconds(50), retry:
                .response(status: 200, prefix: [1, 2, 3], outcome: .failed(code: 7)))
        }, purpose: .recording, reporter: reporter)
    }
}
