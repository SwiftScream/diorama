import DioramaCore
import Testing

private struct ConsumerGroup: Equatable, GroupedReplayRecording {
    let input: String
    let output: Int

    var isOpenAtRecordingHorizon: Bool {
        false
    }
}

struct GroupedSelectorConsumerTests {
    @Test
    func `consumer selectors use public stable values and independent keyed attachments`() async throws {
        let type = ScenarioSystemType("consumer.grouped-selector")
        let policy = ValuePreparation<ConsumerGroup>()
        let first = try makeSystem(type: type, key: "first", values: [
            ConsumerGroup(input: "a", output: 1), ConsumerGroup(input: "b", output: 2),
        ], policy: policy)
        let second = try makeSystem(type: type, key: "second", values: [
            ConsumerGroup(input: "a", output: 10), ConsumerGroup(input: "a", output: 11),
        ], policy: policy)
        let firstTrackID = TrackID(attachmentID: first.attachment.id, key: TrackKey(rawValue: "groups"))
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [first.attachment, second.attachment]),
            scenarioID: ScenarioID(rawValue: "consumer-groups"), defaultMode: .replay,
            systems: [AnyScenarioSystem(second.system), AnyScenarioSystem(first.system)])
        let firstLease = try execution.dependency(first.system)
        let secondLease = try execution.dependency(second.system)
        let exact = GroupedReplaySelector<String, ConsumerGroup>.exactInput(\.input)
        #expect(try firstLease.claimGrouped(matching: "b", using: exact).record.value.output == 2)
        let secondFirst = try secondLease.claimGrouped(matching: "a", using: exact)
        let secondLast = try secondLease.claimGrouped(matching: "a", using: exact)
        #expect(secondFirst.record.value.output == 10)
        #expect(secondLast.record.value.output == 11)
        #expect(secondFirst.complete())
        #expect(secondLast.complete())
        let result = await execution.finish()
        #expect(result.usage.map(\.attachmentID.key.rawValue) == ["first", "second"])
        #expect(result.usage[0].tracks[0].unusedRecords == [
            RecordIdentity(trackID: firstTrackID, sequence: 0),
        ])
        #expect(result.usage[1].tracks[0].unusedRecords.isEmpty)
        #expect(result.evaluate(.allRecordingsUsed, attachments: [second.attachment.id.key]).isSatisfied)
        #expect(result.evaluate(.allSelectedRecordingsCompleted, attachments: [second.attachment.id.key]).isSatisfied)
        #expect(!result.evaluate(.allSelectedRecordingsCompleted).isSatisfied)
        #expect(result.evaluate(.allRecordingsUsed).failures == [
            .unusedRecord(RecordIdentity(trackID: firstTrackID, sequence: 0)),
        ])
    }

    private func makeSystem(
        type: ScenarioSystemType, key: String, values: [ConsumerGroup],
        policy: ValuePreparation<ConsumerGroup>) throws
        -> (attachment: ScenarioAttachment, system: ScenarioSystem<HeaderlessSequentialTrackLease<ConsumerGroup>>)
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
