import DioramaConsumerTestSupport
import DioramaCore
import Synchronization
import Testing

struct RecordingMergeConsumerTests {
    @Test
    func `consumer merges non codable values through public APIs and replays the resulting definition`() async throws {
        let key = AttachmentKey(rawValue: "merged")
        let calls = Mutex(0)
        let system = try ConsumerSequentialSystem.instance(
            key: key, values: [ConsumerStableValue(-7), ConsumerStableValue(2)],
            mergeRecording: { baseline, fresh in
                calls.withLock { $0 += 1 }
                let values = try fresh.records.enumerated().map { position, record in
                    let value = position < baseline.records.count && baseline.records[position].value.number < 0
                        ? baseline.records[position].value : record.value
                    return try ValuePreparation<ConsumerStableValue>().admitPrepared(value)
                }
                return HeaderlessSequentialTrack(id: fresh.id, values: values)
            })
        let baseline = try ScenarioDefinition(attachments: [system.attachment])
        let record = try ScenarioExecution.start(
            definition: baseline, scenarioID: ScenarioID(rawValue: "consumer-merge"), defaultMode: .record,
            systems: [AnyScenarioSystem(system)])
        let dependency = try record.dependency(system)
        #expect(try dependency.next(capturing: { ConsumerStableValue(11) }).number == 11)
        #expect(try dependency.next(capturing: { ConsumerStableValue(12) }).number == 12)
        let result = await record.finish()
        let candidate = try #require(result.definition)
        let old = try #require(try baseline.attachments[0].track(
            ConsumerSequentialSystem.trackID(for: key), as: ConsumerStableValue.self))
        #expect(old.records.map(\.value.number) == [-7, 2])
        #expect(result.report.diagnostics.isEmpty)
        let replay = try ScenarioExecution.start(
            definition: candidate, scenarioID: ScenarioID(rawValue: "consumer-merge-replay"), defaultMode: .replay,
            systems: [AnyScenarioSystem(system)])
        let player = try replay.dependency(system)
        let unexpectedLiveValue = { Issue.record("Replay used live data"); return ConsumerStableValue(0) }
        #expect(try player.next(capturing: unexpectedLiveValue).number == -7)
        #expect(try player.next(capturing: unexpectedLiveValue).number == 12)
        #expect(await replay.finish().report.diagnostics.isEmpty)
        #expect(calls.withLock { $0 } == 1)
    }
}
