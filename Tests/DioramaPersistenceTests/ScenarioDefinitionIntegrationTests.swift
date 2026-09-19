import DioramaCore
import DioramaPersistence
import DioramaRandom
import Testing

struct ScenarioDefinitionIntegrationTests {
    @Test
    func `decoded data runs directly under independent policies without changing its bytes`() async throws {
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([DioramaRandomPersistence.registration]))
        let bytes = try persistedFixture("random-boundaries")
        let definition: ScenarioDefinition = try codec.decode(bytes)
        let probe = StartupProbe()
        let system = try probe.system(key: "boundaries")
        let key = system.attachment.id.key
        let replayPolicy = ScenarioConfiguration(
            id: ScenarioID(rawValue: "replay"), defaultMode: .record,
            modeOverrides: [key: .replay], ignoredAttachments: [key])
        let recordPolicy = ScenarioConfiguration(id: ScenarioID(rawValue: "record"), defaultMode: .record)
        let replay = try ScenarioExecution.start(
            definition: definition, configuration: replayPolicy, systems: [AnyScenarioSystem(system)])
        let record = try ScenarioExecution.start(
            definition: definition, configuration: recordPolicy, systems: [AnyScenarioSystem(system)])
        let replayLease = try replay.dependency(system)
        let recordLease = try record.dependency(system)
        #expect(try replayLease.claimNext().value == 0)
        try recordLease.append(capturing: { 42 }, preparation: ValuePreparation<UInt64>())
        let replayResult = await replay.finish()
        let recordResult = await record.finish()
        #expect(replayResult.report.scenarioID == replayPolicy.id)
        #expect(recordResult.report.scenarioID == recordPolicy.id)
        #expect(replayResult.usage[0].mode == .replay)
        #expect(replayResult.usage[0].isIgnored)
        #expect(replayResult.usage[0].tracks[0].unusedRecords.count == 1)
        #expect(recordResult.usage[0].tracks[0].activity == .record(recordedCount: 1, incompleteCount: 0))
        #expect(try codec.encode(definition) == bytes)
        let second = try ScenarioExecution.start(
            definition: definition, configuration: replayPolicy, systems: [AnyScenarioSystem(system)])
        #expect(try second.dependency(system).claimNext().value == 0)
        _ = await second.finish()
    }

    @Test(arguments: [false, true])
    func `invalid runtime policy stops before repository reads or callbacks`(ignored: Bool) throws {
        let probe = StartupProbe()
        let system = try probe.system(key: "active")
        let unknown = AttachmentKey(rawValue: "unknown")
        let configuration = ScenarioConfiguration(
            id: ScenarioID(rawValue: "invalid-policy"), defaultMode: .record,
            modeOverrides: ignored ? [:] : [unknown: .replay],
            ignoredAttachments: ignored ? [unknown] : [])
        let layout = try ScenarioDefinition(attachments: [system.attachment])
        let storage = StartupStorage()
        let repository = try randomRepository(storage: storage)
        do {
            _ = try repository.start(
                configuredBy: configuration, layout: layout, systems: [AnyScenarioSystem(system)])
            Issue.record("Invalid policy started an execution")
        } catch {
            guard case let .configuration(problem) = error.evidence else {
                Issue.record("Expected configuration evidence before loading"); return
            }
            #expect(problem == (ignored ? .unknownIgnoredAttachment(unknown) : .unknownModeOverride(unknown)))
        }
        #expect(storage.readCount == 0)
        #expect(storage.writeCount == 0)
        #expect(probe.preparationCount == 0)
        #expect(probe.activationCount == 0)
    }
}
