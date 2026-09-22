import DioramaCore
import Synchronization
import Testing

struct ScenarioUsageTests {
    @Test
    func `mixed modes preserve track order and only replay incurs unused obligations`() async throws {
        let replayID = ExecutionFixtures.attachment("replay")
        let first = TrackID(attachmentID: replayID, key: TrackKey(rawValue: "z"))
        let second = TrackID(attachmentID: replayID, key: TrackKey(rawValue: "a"))
        let replay = try ScenarioAttachment(id: replayID)
            .adding(SequentialTrack(id: first, values: preparedValues([11, 12, 13])))
            .adding(SequentialTrack(id: second, values: preparedValues([21])))
        let record = try ScenarioAttachment(id: ExecutionFixtures.attachment("record"))
            .adding(SequentialTrack(id: ExecutionFixtures.track("record"), values: preparedValues([99])))
        let pass = try ScenarioAttachment(id: ExecutionFixtures.attachment("pass"))
            .adding(SequentialTrack(id: ExecutionFixtures.track("pass"), values: preparedValues([99])))
        let definition = try ScenarioDefinition(attachments: [replay, record, pass])
        let journal = ExecutionFixtures.Journal()
        let replayInstance = try ScenarioSystem(type: ExecutionFixtures.type, attachment: replay) { context in
            // Lease request order deliberately differs from declaration order.
            let secondLease = try context.lease(for: second, preparation: ValuePreparation<Int>())
            let firstLease = try context.lease(for: first, preparation: ValuePreparation<Int>())
            return PreparedSystem { ActivatedSystem(dependency: [firstLease, secondLease], deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: definition,
            scenarioID: ScenarioID(rawValue: "mixed"), defaultMode: .replay,
            systems: [
                ExecutionFixtures.system("pass", journal: journal, mode: .passthrough),
                AnyScenarioSystem(replayInstance),
                ExecutionFixtures.system("record", journal: journal, mode: .record),
            ])
        let leases = try execution.dependency(replayInstance)
        #expect(try leases[0].claimNext().value == 11)
        #expect(try leases[1].claimNext().value == 21)
        #expect(throws: SequentialOperationFailure.self) { try leases[1].claimNext() }
        let recording = try execution.dependency(
            DependencyKey<SequentialTrackLease<Int>>(attachmentID: record.id))
        try recording.append(capturing: { 42 }, preparation: ValuePreparation<Int>())
        let result = await execution.finish()
        #expect(result.usage.map(\.attachmentID) == [replay.id, record.id, pass.id])
        #expect(result.usage.map(\.mode) == [.replay, .record, .passthrough])
        #expect(result.usage[0].tracks.map(\.id) == [first, second])
        #expect(result.usage.flatMap(\.tracks).map(\.activity) == [
            .replay(usedCount: 1, unusedCount: 2), .replay(usedCount: 1, unusedCount: 0),
            .record(recordedCount: 1, incompleteCount: 0), .passthrough,
        ])
        #expect(result.evaluate(.allRecordingsUsed).failures == [
            .unusedRecord(RecordIdentity(trackID: first, sequence: 1)),
            .unusedRecord(RecordIdentity(trackID: first, sequence: 2)),
        ])
        #expect(!result.evaluate(.noUnexpectedOperations).isSatisfied)
        #expect(result.evaluate(.allRecordingsUsed, attachments: [record.id.key, pass.id.key]).isSatisfied)
        #expect(await execution.finish() == result)
    }

    @Test
    func `ignoring active usage preserves preparation health and operation diagnostics`() async throws {
        let base = try ExecutionFixtures.definition(["a"])
        let definition = try ScenarioDefinition(attachments: base.attachments)
        let preparations = Mutex(0)
        let instance = try ScenarioSystem(type: ExecutionFixtures.type,
                                          attachment: definition.attachments[0],
                                          allowsUnusedReplayRecords: true)
        { context in
            let lease = try context.lease(
                for: ExecutionFixtures.track("a"), preparation: ValuePreparation<Int>(validate: { _ in
                    preparations.withLock { $0 += 1 }
                }))
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "execution"), defaultMode: .replay,
            systems: [AnyScenarioSystem(instance)])
        let lease = try execution.dependency(instance)
        #expect(throws: SequentialOperationFailure.self) {
            try lease.append(capturing: { 4 }, preparation: ValuePreparation<Int>())
        }
        #expect(lease.report(.system(DiagnosticLabel("unhealthy")), recordingImpact: .invalidatesCandidate))
        let result = await execution.finish()
        #expect(preparations.withLock { $0 } == 2)
        #expect(result.usage[0].tracks[0].unusedRecords.count == 2)
        #expect(result.evaluate(.allRecordingsUsed).isSatisfied)
        #expect(!result.evaluate(.healthyRecording).isSatisfied)
        #expect(!result.evaluate(.noUnexpectedOperations).isSatisfied)
    }
}
