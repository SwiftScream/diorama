import DioramaCore
import Synchronization
import Testing

struct ScenarioCandidateTests {
    @Test
    func `record replaces complete tracks while replay and passthrough preserve the immutable baseline`() async throws {
        let baseline = try ExecutionFixtures.definition(["record", "empty", "replay", "passthrough"])
        let journal = ExecutionFixtures.Journal()
        let execution = try ScenarioExecution.start(
            definition: baseline, scenarioID: ScenarioID(rawValue: "candidate"), defaultMode: .record,
            systems: [
                ExecutionFixtures.system("record", journal: journal),
                ExecutionFixtures.system("empty", journal: journal),
                ExecutionFixtures.system("replay", journal: journal, mode: .replay),
                ExecutionFixtures.system("passthrough", journal: journal, mode: .passthrough),
            ])
        let recorded = try execution.dependency(
            ExecutionFixtures.dependencyKey("record", as: SequentialTrackLease<Int>.self))
        let transformations = Mutex(0)
        let preparation = ValuePreparation<Int>(normalize: { value in
            transformations.withLock { $0 += 1 }
            return value + 10
        })
        try recorded.append(capturing: { 3 }, preparation: preparation)
        try recorded.append(capturing: { 4 }, preparation: preparation)
        let replayed = try execution.dependency(
            ExecutionFixtures.dependencyKey("replay", as: SequentialTrackLease<Int>.self))
        #expect(try replayed.claimNext().value == 1)
        let result = await execution.finish()
        let definition = try #require(result.definition)
        #expect(definition.attachments.map(\.id) == baseline.attachments.map(\.id))
        #expect(try values("record", in: definition) == [13, 14])
        #expect(try values("empty", in: definition).isEmpty)
        #expect(try values("replay", in: definition) == [1, 2])
        #expect(try values("passthrough", in: definition) == [1, 2])
        #expect(try values("record", in: baseline) == [1, 2])
        let repeated = await execution.finish()
        #expect(try values("record", in: #require(repeated.definition)) == [13, 14])
        #expect(transformations.withLock { $0 } == 2)
        #expect(recorded.isClosed)
    }

    @Test
    func `one failed admission suppresses the whole resulting definition`() async throws {
        let journal = ExecutionFixtures.Journal()
        let execution = try ScenarioExecution.start(
            definition: ExecutionFixtures.definition(["healthy", "failed"]),
            scenarioID: ScenarioID(rawValue: "candidate"), defaultMode: .record,
            systems: [
                ExecutionFixtures.system("healthy", journal: journal),
                ExecutionFixtures.system("failed", journal: journal),
            ])
        let healthy = try execution.dependency(
            ExecutionFixtures.dependencyKey("healthy", as: SequentialTrackLease<Int>.self))
        let failed = try execution.dependency(
            ExecutionFixtures.dependencyKey("failed", as: SequentialTrackLease<Int>.self))
        try healthy.append(capturing: { 9 }, preparation: ValuePreparation<Int>())
        #expect(throws: SequentialOperationFailure.self) {
            try failed.append(capturing: { 10 }, preparation: ValuePreparation<Int>(validate: { _ in
                throw ExecutionFixtures.SecretError(journal: journal)
            }))
        }
        try failed.append(capturing: { 11 }, preparation: ValuePreparation<Int>())
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(result.usage.map { $0.tracks[0].activity } == [
            .record(recordedCount: 1, incompleteCount: 0), .record(recordedCount: 1, incompleteCount: 1),
        ])
        #expect(journal.descriptions.withLock { $0 } == 0)
    }

    @Test
    func `empty scenarios still produce complete definitions`() async throws {
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(), scenarioID: ScenarioID(rawValue: "empty"),
            defaultMode: .record, systems: [])
        let result = await execution.finish()
        #expect(try #require(result.definition).attachments.isEmpty)
    }

    private func values(_ key: String, in definition: ScenarioDefinition) throws -> [Int] {
        let attachment = try #require(definition.attachment(for: AttachmentKey(rawValue: key)))
        let track = try #require(try attachment.track(ExecutionFixtures.track(key), as: Int.self))
        #expect(track.records.map(\.identity.sequence) == Array(0..<UInt64(track.records.count)))
        return track.records.map(\.value)
    }
}
