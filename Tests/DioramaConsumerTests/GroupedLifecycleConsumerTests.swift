import DioramaCore
import Testing

struct GroupedLifecycleConsumerTests {
    private typealias Call = InteractionRecording<String, String, String, String, String>

    private struct Dependency: Sendable {
        let time: ExecutionTime
        let lease: HeaderlessSequentialTrackLease<Call>
        let reporter: DiagnosticReporter
    }

    @Test
    func `a public consumer system records and freezes a typed interaction`() async throws {
        let type = ScenarioSystemType("grouped-consumer")
        let id = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: "one"))
        let trackID = TrackID(attachmentID: id, key: TrackKey(rawValue: "calls"))
        let attachment = try ScenarioAttachment(id: id).adding(HeaderlessSequentialTrack<Call>(id: trackID))
        let groupPolicy = ValuePreparation<Call>()
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let lease = try context.lease(for: trackID, preparation: groupPolicy)
            let dependency = Dependency(time: context.time, lease: lease, reporter: context.reporter)
            return PreparedSystem { ActivatedSystem(dependency: dependency, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "grouped-consumer"), defaultMode: .record,
            systems: [AnyScenarioSystem(system)])
        let dependency = try execution.dependency(system)
        let call = try dependency.lease.beginInteraction(at: dependency.time.capture(), preparation: groupPolicy) {
            try ValuePreparation<String>().prepare(
                capturing: { "input" }, purpose: .recording, reporter: dependency.reporter)
        }
        _ = try call.observe(at: dependency.time.capture()) {
            try ValuePreparation<String>().prepare(
                capturing: { "phase" }, purpose: .recording, reporter: dependency.reporter)
        }
        let result = await execution.finish()
        let definition = try #require(result.definition)
        let stored = try #require(try definition.attachment(for: id.key)?.track(trackID, as: Call.self))
        #expect(stored.records.count == 1)
        #expect(stored.records[0].value.input == "input")
        #expect(stored.records[0].value.phases[0].observation.value == "phase")
        #expect(stored.records[0].value.conclusion == .openAtRecordingHorizon)
    }
}
