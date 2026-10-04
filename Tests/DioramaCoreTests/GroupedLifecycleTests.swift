@testable import DioramaCore
import Testing

enum GroupedFixtures {
    typealias Interaction = InteractionRecording<String, String, String, String, String>

    struct Dependency: Sendable {
        let time: ExecutionTime
        let interactions: HeaderlessSequentialTrackLease<Interaction>
        let reporter: DiagnosticReporter
    }

    static let type = ScenarioSystemType("grouped")
    static let attachmentID = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: "one"))
    static let interactionID = TrackID(attachmentID: attachmentID, key: TrackKey(rawValue: "interactions"))

    static func setup(clock: SchedulerTestClock) throws -> (ScenarioExecution, Dependency) {
        let attachment = try ScenarioAttachment(id: attachmentID)
            .adding(HeaderlessSequentialTrack<Interaction>(id: interactionID))
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let interactions = try context.lease(for: interactionID, preparation: ValuePreparation<Interaction>())
            let dependency = Dependency(time: context.time, interactions: interactions, reporter: context.reporter)
            return PreparedSystem { ActivatedSystem(dependency: dependency, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "grouped"), defaultMode: .record,
            systems: [AnyScenarioSystem(system)], clock: clock.source)
        return try (execution, execution.dependency(system))
    }

    static func prepared(_ text: String, reporter: DiagnosticReporter) throws -> PreparedValue<String> {
        try ValuePreparation<String>().prepare(capturing: { text }, purpose: .recording, reporter: reporter)
    }

    static func interactions(in result: ScenarioFinalizationResult) throws -> [SequentialRecord<Interaction>] {
        let definition = try #require(result.definition)
        let attachment = try #require(definition.attachment(for: attachmentID.key))
        return try #require(try attachment.track(interactionID, as: Interaction.self)).records
    }
}

@Suite(.timeLimit(.minutes(1)))
struct GroupedLifecycleTests {
    @Test
    func `overlapping interactions retain begin order correlated phases and explicit open conclusion`() async throws {
        let clock = SchedulerTestClock()
        let (execution, dependency) = try GroupedFixtures.setup(clock: clock)
        let time = dependency.time
        let reporter = dependency.reporter
        let preparation = ValuePreparation<GroupedFixtures.Interaction>()
        let first = try dependency.interactions.beginInteraction(at: time.capture(), preparation: preparation) {
            try GroupedFixtures.prepared("first", reporter: reporter)
        }
        clock.advance(to: .milliseconds(1))
        let second = try dependency.interactions.beginInteraction(at: time.capture(), preparation: preparation) {
            try GroupedFixtures.prepared("second", reporter: reporter)
        }
        clock.advance(to: .milliseconds(2))
        let early = try first.observe(at: time.capture()) {
            try GroupedFixtures.prepared("early", reporter: reporter)
        }
        clock.advance(to: .milliseconds(3))
        _ = try first.observe(at: time.capture()) {
            try GroupedFixtures.prepared("later", reporter: reporter)
        }
        clock.advance(to: .milliseconds(4))
        try second.failed(at: time.capture()) {
            try GroupedFixtures.prepared("second-failed", reporter: reporter)
        }
        clock.advance(to: .milliseconds(5))
        try first.respond(to: early, at: time.capture()) {
            try GroupedFixtures.prepared("answered", reporter: reporter)
        }
        clock.advance(to: .milliseconds(6))
        try first.returned(at: time.capture()) {
            try GroupedFixtures.prepared("first-returned", reporter: reporter)
        }
        clock.advance(to: .milliseconds(7))
        let open = try dependency.interactions.beginInteraction(at: time.capture(), preparation: preparation) {
            try GroupedFixtures.prepared("open", reporter: reporter)
        }
        let result = await execution.finish()
        try assertOverlappingInteractions(result, open: open)
    }

    private func assertOverlappingInteractions(
        _ result: ScenarioFinalizationResult,
        open: InteractionAccumulator<String, String, String, String, String>) throws
    {
        let groups = try GroupedFixtures.interactions(in: result)
        #expect(groups.map(\.identity.sequence) == [0, 1, 2])
        #expect(groups.map(\.value.input) == ["first", "second", "open"])
        #expect(groups[0].value.phases.map(\.observation.value) == ["early", "later"])
        #expect(groups[0].value.phases.map(\.observation.offset) == [.milliseconds(2), .milliseconds(3)])
        #expect(groups[0].value.phases[0].decision?.value == "answered")
        #expect(groups[0].value.phases[0].decision?.offset == .milliseconds(5))
        #expect(try groups[0].value.conclusion == .returned(LifecycleMoment(offset: .milliseconds(6),
                                                                            value: "first-returned")))
        #expect(try groups[1].value.conclusion == .failed(LifecycleMoment(offset: .milliseconds(3),
                                                                          value: "second-failed")))
        #expect(groups[2].value.conclusion == .openAtRecordingHorizon)
        #expect(open.identity.sequence == 2)
        #expect(result.report.recordingHealth.isHealthy)
    }

    @Test
    func `group position reserves before nested input capture`() async throws {
        let clock = SchedulerTestClock()
        let (execution, dependency) = try GroupedFixtures.setup(clock: clock)
        let time = dependency.time
        let reporter = dependency.reporter
        let preparation = ValuePreparation<GroupedFixtures.Interaction>()
        let firstCapture = try time.capture()
        var nested: InteractionAccumulator<String, String, String, String, String>?
        let first = try dependency.interactions.beginInteraction(at: firstCapture, preparation: preparation) {
            nested = try dependency.interactions.beginInteraction(at: time.capture(), preparation: preparation) {
                try GroupedFixtures.prepared("nested", reporter: reporter)
            }
            return try GroupedFixtures.prepared("outer", reporter: reporter)
        }
        #expect(first.identity.sequence == 0)
        #expect(nested?.identity.sequence == 1)
        let result = await execution.finish()
        #expect(try GroupedFixtures.interactions(in: result).map(\.value.input) == ["outer", "nested"])
    }
}
