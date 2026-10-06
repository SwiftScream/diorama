import DioramaCore
import Testing

private struct ConsumerRecord: Equatable, Sendable {
    let input: String
    let output: Int
}

struct RecordSelectorConsumerTests {
    @Test
    func `consumer selectors use public stable values and independent keyed attachments`() async throws {
        let type = ScenarioSystemType("consumer.record-selector")
        let policy = ValuePreparation<ConsumerRecord>()
        let first = try makeSystem(type: type, key: "first", values: [
            ConsumerRecord(input: "a", output: 1), ConsumerRecord(input: "b", output: 2),
        ], policy: policy)
        let second = try makeSystem(type: type, key: "second", values: [
            ConsumerRecord(input: "a", output: 10), ConsumerRecord(input: "a", output: 11),
        ], policy: policy)
        let firstTrackID = TrackID(attachmentID: first.attachment.id, key: TrackKey(rawValue: "groups"))
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [first.attachment, second.attachment]),
            scenarioID: ScenarioID(rawValue: "consumer-groups"), defaultMode: .replay,
            systems: [AnyScenarioSystem(second.system), AnyScenarioSystem(first.system)])
        let firstLease = try execution.dependency(first.system)
        let secondLease = try execution.dependency(second.system)
        let exact = ReplaySelector<String, ConsumerRecord>.exactInput(\.input)
        #expect(try firstLease.claim(matching: "b", using: exact).record.value.output == 2)
        let secondFirst = try secondLease.claim(matching: "a", using: exact)
        let secondLast = try secondLease.claim(matching: "a", using: exact)
        #expect(secondFirst.record.value.output == 10)
        #expect(secondLast.record.value.output == 11)
        #expect(secondFirst.markConsumed())
        #expect(secondLast.markConsumed())
        let result = await execution.finish()
        #expect(result.usage.map(\.attachmentID.key.rawValue) == ["first", "second"])
        #expect(result.usage[0].tracks[0].unclaimedRecords == [
            RecordIdentity(trackID: firstTrackID, sequence: 0),
        ])
        #expect(result.usage[1].tracks[0].unclaimedRecords.isEmpty)
        #expect(result.evaluate(.allRecordsClaimed, attachments: [second.attachment.id.key]).isSatisfied)
        #expect(result.evaluate(.allClaimedRecordsConsumed, attachments: [second.attachment.id.key]).isSatisfied)
        #expect(!result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(result.evaluate(.allRecordsClaimed).failures == [
            .unclaimedRecord(RecordIdentity(trackID: firstTrackID, sequence: 0)),
        ])
    }

    private func makeSystem(
        type: ScenarioSystemType, key: String, values: [ConsumerRecord],
        policy: ValuePreparation<ConsumerRecord>) throws
        -> (attachment: ScenarioAttachment, system: ScenarioSystem<HeaderlessSequentialTrackLease<ConsumerRecord>>)
    {
        let attachmentID = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: key))
        let trackID = TrackID(attachmentID: attachmentID, key: TrackKey(rawValue: "groups"))
        let prepared = try values.map { try policy.admitPrepared($0) }
        let attachment = try ScenarioAttachment(id: attachmentID)
            .adding(SequentialTrack(id: trackID, values: prepared))
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let lease = try context.lease(for: trackID, preparation: policy)
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        return (attachment, system)
    }
}
