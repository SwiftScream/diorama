import Diorama
import DioramaCore
import DioramaPersistence
import DioramaRandom
import Testing

struct ScenarioDefinitionIntegrationTests {
    @Test
    func `decoded data runs directly under independent policies without changing its bytes`() async throws {
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([DioramaRandomSystem.type]))
        let bytes = try persistedFixture("random-boundaries")
        let definition: ScenarioDefinition = try codec.decode(bytes)
        let probe = StartupProbe()
        let system = try probe.system(key: "boundaries", allowsUnusedReplayRecords: true)
        let replaySystem = system.withMode(.replay)

        let replay = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "replay"), defaultMode: .record,
            systems: [AnyScenarioSystem(replaySystem)])
        let record = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "record"), defaultMode: .record,
            systems: [AnyScenarioSystem(system)])
        let replayLease = try replay.dependency(system)
        let recordLease = try record.dependency(system)
        #expect(try replayLease.claimNext().value == 0)
        try recordLease.append(capturing: { 42 }, preparation: ValuePreparation<UInt64>())
        let replayResult = await replay.finish()
        let recordResult = await record.finish()
        #expect(replayResult.report.scenarioID == ScenarioID(rawValue: "replay"))
        #expect(recordResult.report.scenarioID == ScenarioID(rawValue: "record"))
        #expect(replayResult.usage[0].mode == .replay)
        #expect(replayResult.usage[0].allowsUnusedReplayRecords)
        #expect(replayResult.usage[0].tracks[0].unusedRecords.count == 1)
        #expect(recordResult.usage[0].tracks[0].activity == .record(recordedCount: 1, incompleteCount: 0))
        #expect(try codec.encode(definition) == bytes)
        let second = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "replay"), defaultMode: .record,
            systems: [AnyScenarioSystem(replaySystem)])
        #expect(try second.dependency(system).claimNext().value == 0)
        _ = await second.finish()
    }
}
