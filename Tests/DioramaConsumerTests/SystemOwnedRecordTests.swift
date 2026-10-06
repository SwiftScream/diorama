import DioramaCore
import Synchronization
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

private final class ConsumerOperationDraft: Sendable {
    private let state: Mutex<ConsumerOperation?>

    init(input: PreparedValue<String>) {
        state = Mutex(ConsumerOperation(request: input.value, path: .open))
    }

    func observe(_ path: PreparedValue<ConsumerOperation.Path>) -> Bool {
        state.withLock { value in
            guard let current = value else { return false }
            value = ConsumerOperation(request: current.request, path: path.value)
            return true
        }
    }

    func freeze() -> ConsumerOperation? {
        state.withLock { value in
            let detached = value
            value = nil
            return detached
        }
    }
}

struct SystemOwnedRecordTests {
    @Test
    func `consumer owns recursive partial and open records across capture and selection`() async throws {
        let type = ScenarioSystemType("consumer.operations")
        let id = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: "one"))
        let trackID = TrackID(attachmentID: id, key: TrackKey(rawValue: "operations"))
        let attachment = try ScenarioAttachment(id: id)
            .adding(HeaderlessSequentialTrack<ConsumerOperation>(id: trackID))
        let policy = ValuePreparation<ConsumerOperation>()
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let lease = try context.lease(for: trackID, preparation: policy)
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let recording = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "domain-records"), defaultMode: .record,
            systems: [AnyScenarioSystem(system)])
        let lease = try recording.dependency(system)
        let draft = try lease.beginRecord(preparation: policy, capturing: { identity in
            let input = try ValuePreparation<String>().prepare(capturing: { "request" },
                                                               purpose: .recording, reporter: lease.reporter,
                                                               context: .record(identity))
            return ConsumerOperationDraft(input: input)
        }, freeze: { $0.freeze() })
        let path = try preparedPath(reporter: lease.reporter)
        #expect(draft.observe(path))
        _ = try lease.beginRecord(preparation: policy, capturing: { _ in
            let input = try ValuePreparation<String>().prepare(
                capturing: { "pending" }, purpose: .recording, reporter: lease.reporter)
            return ConsumerOperationDraft(input: input)
        }, freeze: { $0.freeze() })
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
