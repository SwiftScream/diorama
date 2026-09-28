@testable import DioramaCore
import Dispatch
import Testing

enum GroupedFixtures {
    typealias Interaction = InteractionRecording<String, String, String, String, String>
    typealias Subscription = SubscriptionRecording<String, String, String>

    struct Dependency: Sendable {
        let time: ExecutionTime
        let interactions: HeaderlessSequentialTrackLease<Interaction>
        let subscriptions: HeaderlessSequentialTrackLease<Subscription>
        let reporter: DiagnosticReporter
    }

    static let type = ScenarioSystemType("grouped")
    static let attachmentID = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: "one"))
    static let interactionID = TrackID(attachmentID: attachmentID, key: TrackKey(rawValue: "interactions"))
    static let subscriptionID = TrackID(attachmentID: attachmentID, key: TrackKey(rawValue: "subscriptions"))

    static func setup(clock: SchedulerTestClock) throws -> (ScenarioExecution, Dependency) {
        let attachment = try ScenarioAttachment(id: attachmentID)
            .adding(HeaderlessSequentialTrack<Interaction>(id: interactionID))
            .adding(HeaderlessSequentialTrack<Subscription>(id: subscriptionID))
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let interactions = try context.lease(for: interactionID, preparation: ValuePreparation<Interaction>())
            let subscriptions = try context.lease(for: subscriptionID, preparation: ValuePreparation<Subscription>())
            let dependency = Dependency(time: context.time, interactions: interactions,
                                        subscriptions: subscriptions, reporter: context.reporter)
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

    static func subscriptions(in result: ScenarioFinalizationResult) throws -> [SequentialRecord<Subscription>] {
        let definition = try #require(result.definition)
        let attachment = try #require(definition.attachment(for: attachmentID.key))
        return try #require(try attachment.track(subscriptionID, as: Subscription.self)).records
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
    func `subscriptions distinguish nonterminal errors terminal failures and open horizons`() async throws {
        let clock = SchedulerTestClock()
        let (execution, dependency) = try GroupedFixtures.setup(clock: clock)
        let time = dependency.time
        let reporter = dependency.reporter
        let preparation = ValuePreparation<GroupedFixtures.Subscription>()
        let first = try dependency.subscriptions.beginSubscription(at: time.capture(), preparation: preparation) {
            try GroupedFixtures.prepared("first", reporter: reporter)
        }
        let second = try dependency.subscriptions.beginSubscription(at: time.capture(), preparation: preparation) {
            try GroupedFixtures.prepared("second", reporter: reporter)
        }
        clock.advance(to: .milliseconds(1))
        try first.deliver(at: time.capture()) { try GroupedFixtures.prepared("a", reporter: reporter) }
        clock.advance(to: .milliseconds(2))
        try first.reportNonterminalFailure(at: time.capture()) {
            try GroupedFixtures.prepared("temporary", reporter: reporter)
        }
        clock.advance(to: .milliseconds(3))
        try second.fail(at: time.capture()) { try GroupedFixtures.prepared("terminal", reporter: reporter) }
        clock.advance(to: .milliseconds(4))
        try first.deliver(at: time.capture()) { try GroupedFixtures.prepared("b", reporter: reporter) }
        clock.advance(to: .milliseconds(5))
        try first.finish(at: time.capture())
        clock.advance(to: .milliseconds(6))
        _ = try dependency.subscriptions.beginSubscription(at: time.capture(), preparation: preparation) {
            try GroupedFixtures.prepared("open", reporter: reporter)
        }
        let result = await execution.finish()
        let groups = try GroupedFixtures.subscriptions(in: result)
        #expect(groups.map(\.value.input) == ["first", "second", "open"])
        #expect(try groups[0].value.events == [
            .delivered(LifecycleMoment(offset: .milliseconds(1), value: "a")),
            .reported(LifecycleMoment(offset: .milliseconds(2), value: "temporary")),
            .delivered(LifecycleMoment(offset: .milliseconds(4), value: "b")),
        ])
        #expect(groups[0].value.conclusion == .finished(atTime: .milliseconds(5)))
        #expect(try groups[1].value.conclusion == .failed(LifecycleMoment(offset: .milliseconds(3),
                                                                          value: "terminal")))
        #expect(groups[2].value.conclusion == .openAtRecordingHorizon)
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

    @Test
    func `slow stream conversion keeps its reserved event order`() async throws {
        let clock = SchedulerTestClock()
        let (execution, dependency) = try GroupedFixtures.setup(clock: clock)
        let reporter = dependency.reporter
        let time = dependency.time
        let stream = try dependency.subscriptions.beginSubscription(
            at: time.capture(), preparation: ValuePreparation<GroupedFixtures.Subscription>())
        { try GroupedFixtures.prepared("stream", reporter: reporter) }
        clock.advance(to: .milliseconds(1))
        let firstCapture = try time.capture()
        let entered = AsyncStream<Void>.makeStream()
        let complete = AsyncStream<Bool>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue.global().async {
            let admitted = (try? stream.deliver(at: firstCapture) {
                entered.continuation.finish()
                release.wait()
                return try GroupedFixtures.prepared("first", reporter: reporter)
            }) != nil
            complete.continuation.yield(admitted)
            complete.continuation.finish()
        }
        for await _ in entered.stream {}
        clock.advance(to: .milliseconds(2))
        try stream.deliver(at: time.capture()) { try GroupedFixtures.prepared("second", reporter: reporter) }
        release.signal()
        for await admitted in complete.stream {
            #expect(admitted)
        }
        let result = await execution.finish()
        let events = try GroupedFixtures.subscriptions(in: result)[0].value.events
        #expect(try events == [
            .delivered(LifecycleMoment(offset: .milliseconds(1), value: "first")),
            .delivered(LifecycleMoment(offset: .milliseconds(2), value: "second")),
        ])
    }

    @Test
    func `an unfinished conversion at the horizon invalidates the complete candidate`() async throws {
        let clock = SchedulerTestClock()
        let (execution, dependency) = try GroupedFixtures.setup(clock: clock)
        let reporter = dependency.reporter
        let time = dependency.time
        let stream = try dependency.subscriptions.beginSubscription(
            at: time.capture(), preparation: ValuePreparation<GroupedFixtures.Subscription>())
        { try GroupedFixtures.prepared("stream", reporter: reporter) }
        let capture = try time.capture()
        let entered = AsyncStream<Void>.makeStream()
        let complete = AsyncStream<Bool>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue.global().async {
            let rejected = (try? stream.deliver(at: capture) {
                entered.continuation.finish()
                release.wait()
                return try GroupedFixtures.prepared("too-late", reporter: reporter)
            }) == nil
            complete.continuation.yield(rejected)
            complete.continuation.finish()
        }
        for await _ in entered.stream {}
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.sequential(.grouped(.incompleteGroup))])
        #expect(result.usage[0].tracks[1].activity == .record(recordedCount: 0, incompleteCount: 1))
        release.signal()
        for await rejected in complete.stream {
            #expect(rejected)
        }
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue)
            == [.sequential(.grouped(.lateObservation))])
    }
}
