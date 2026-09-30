@testable import DioramaCore
import Testing

private enum StreamFixtures {
    typealias Recording = SubscriptionRecording<String, String, String>

    struct Dependency: Sendable {
        let lease: HeaderlessSequentialTrackLease<Recording>
        let time: ExecutionTime
        let scheduling: SchedulingLease
    }

    static func recording(_ input: String, events: [SubscriptionEvent<String, String>] = [],
                          conclusion: SubscriptionConclusion<String>) throws -> Recording
    {
        try Recording(input: input, events: events, conclusion: conclusion)
    }

    static func value(_ text: String, at offset: Duration) throws -> SubscriptionEvent<String, String> {
        try .delivered(LifecycleMoment(offset: offset, value: text))
    }

    static func error(_ text: String, at offset: Duration) throws -> SubscriptionEvent<String, String> {
        try .reported(LifecycleMoment(offset: offset, value: text))
    }

    static func start(_ recordings: [Recording], clock: SchedulerTestClock) throws -> (ScenarioExecution, Dependency) {
        let type = ScenarioSystemType("stream-replay")
        let attachmentID = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: "source"))
        let trackID = TrackID(attachmentID: attachmentID, key: TrackKey(rawValue: "subscriptions"))
        let policy = ValuePreparation<Recording>()
        let values = try recordings.map { try policy.admitPrepared($0) }
        let attachment = try ScenarioAttachment(id: attachmentID)
            .adding(SequentialTrack(id: trackID, values: values))
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let lease = try context.lease(for: trackID, preparation: policy)
            let dependency = Dependency(lease: lease, time: context.time, scheduling: context.scheduling)
            return PreparedSystem { ActivatedSystem(dependency: dependency, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]), scenarioID: ScenarioID(rawValue: "streams"),
            defaultMode: .replay, systems: [AnyScenarioSystem(system)], clock: clock.source)
        return try (execution, execution.dependency(system))
    }

    static func subscribe(_ dependency: Dependency, input: String,
                          journal: SchedulerJournal) throws -> StreamReplaySubscription<String, String, String>
    {
        try dependency.lease.replaySubscription(
            matching: input, using: .exactInput(\.input), time: dependency.time,
            scheduling: dependency.scheduling)
        { delivery in
            switch delivery {
            case let .value(value): journal.append("value:\(value)")
            case let .nonterminalFailure(error): journal.append("error:\(error)")
            case .finished: journal.append("finished")
            case let .failed(error): journal.append("failed:\(error)")
            }
        }
    }
}

private final class StreamReleaseProbe: Sendable {
    private let released: AsyncStream<Void>.Continuation

    init(released: AsyncStream<Void>.Continuation) {
        self.released = released
    }

    deinit { released.finish() }
}

private func deliveryHolding(_ probe: StreamReleaseProbe)
    -> @Sendable (StreamReplayDelivery<String, String>) async -> Void
{
    { _ in withExtendedLifetime(probe) {} }
}

@Suite(.timeLimit(.minutes(1)))
struct SequentialStreamReplayTests {
    @Test
    func `subscriptions get fresh anchors and preserve event order and terminal completion`() async throws {
        let clock = SchedulerTestClock()
        let group = try StreamFixtures.recording("same", events: [
            StreamFixtures.value("first", at: .seconds(2)),
            StreamFixtures.error("temporary", at: .seconds(2)),
            StreamFixtures.value("recovered", at: .seconds(2)),
        ], conclusion: .finished(atTime: nil))
        let (execution, dependency) = try StreamFixtures.start([group, group], clock: clock)
        let journal = SchedulerJournal()
        let first = try StreamFixtures.subscribe(dependency, input: "same", journal: journal)
        #expect(try await clock.nextSleep().deadline == .seconds(2))
        clock.advance(to: .seconds(2))
        #expect(await journal.take(4) == [
            "value:first", "error:temporary", "value:recovered", "finished",
        ])
        let second = try StreamFixtures.subscribe(dependency, input: "same", journal: journal)
        #expect(try await clock.nextSleep().deadline == .seconds(4))
        clock.advance(to: .seconds(4))
        #expect(await journal.take(4) == [
            "value:first", "error:temporary", "value:recovered", "finished",
        ])
        let result = await execution.finish()
        #expect(!first.cancel())
        #expect(!second.cancel())
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.usage[0].tracks[0].selectedGroups.map(\.progressCount) == [3, 3])
        #expect(result.usage[0].tracks[0].selectedGroups.map(\.conclusion) == [.completed, .completed])
    }

    @Test
    func `empty and open groups keep their distinct conclusions`() async throws {
        let clock = SchedulerTestClock()
        let open = try StreamFixtures.recording("open", conclusion: .openAtRecordingHorizon)
        let empty = try StreamFixtures.recording("empty", conclusion: .finished(atTime: nil))
        let failed = try StreamFixtures.recording("failed", conclusion: .failed(
            LifecycleMoment(offset: .zero, value: "terminal")))
        let (execution, dependency) = try StreamFixtures.start([open, empty, failed], clock: clock)
        let journal = SchedulerJournal()
        let openSubscription = try StreamFixtures.subscribe(dependency, input: "open", journal: journal)
        let emptySubscription = try StreamFixtures.subscribe(dependency, input: "empty", journal: journal)
        let failedSubscription = try StreamFixtures.subscribe(dependency, input: "failed", journal: journal)
        #expect(await Set(journal.take(2)) == Set(["finished", "failed:terminal"]))
        #expect(openSubscription.cancel())
        #expect(!openSubscription.cancel())
        let result = await execution.finish()
        #expect(!emptySubscription.cancel())
        #expect(!failedSubscription.cancel())
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.usage[0].tracks[0].selectedGroups.map(\.conclusion) == [
            .openAtRecordingHorizon, .completed, .completed,
        ])
    }

    @Test
    func `open group remains without a synthetic completion after its last value`() async throws {
        let clock = SchedulerTestClock()
        let open = try StreamFixtures.recording("open", events: [
            StreamFixtures.value("only", at: .zero),
        ], conclusion: .openAtRecordingHorizon)
        let (execution, dependency) = try StreamFixtures.start([open], clock: clock)
        let journal = SchedulerJournal()
        let subscription = try StreamFixtures.subscribe(dependency, input: "open", journal: journal)
        #expect(await journal.take(1) == ["value:only"])
        let result = await execution.finish()
        #expect(journal.values == ["value:only"])
        #expect(result.usage[0].tracks[0].selectedGroups[0].progressCount == 1)
        #expect(result.usage[0].tracks[0].selectedGroups[0].conclusion == .openAtRecordingHorizon)
        #expect(result.evaluate(.allSelectedRecordingsCompleted).isSatisfied)
        #expect(subscription.cancel())
    }

    @Test
    func `failed selection does not schedule delivery`() async throws {
        let clock = SchedulerTestClock()
        let group = try StreamFixtures.recording("available", conclusion: .finished(atTime: nil))
        let (execution, dependency) = try StreamFixtures.start([group], clock: clock)
        let journal = SchedulerJournal()
        #expect(throws: SequentialOperationFailure.self) {
            try StreamFixtures.subscribe(dependency, input: "missing", journal: journal)
        }
        let result = await execution.finish()
        #expect(journal.values.isEmpty)
        #expect(result.usage[0].tracks[0].activity == .replay(usedCount: 0, unusedCount: 1))
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.sequential(.selection(.noMatch))])
    }

    @Test
    func `escaped handle does not retain pending delivery captures after finish`() async throws {
        let clock = SchedulerTestClock()
        let group = try StreamFixtures.recording("later", events: [
            StreamFixtures.value("never", at: .seconds(60)),
        ], conclusion: .openAtRecordingHorizon)
        let (execution, dependency) = try StreamFixtures.start([group], clock: clock)
        let released = AsyncStream<Void>.makeStream()
        let subscription = try dependency.lease.replaySubscription(
            matching: "later", using: .exactInput(\.input), time: dependency.time,
            scheduling: dependency.scheduling,
            deliver: deliveryHolding(StreamReleaseProbe(released: released.continuation)))
        #expect(try await clock.nextSleep().deadline == .seconds(60))
        let result = await execution.finish()
        for await _ in released.stream {}
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.usage[0].tracks[0].selectedGroups[0].conclusion == .openAtRecordingHorizon)
        withExtendedLifetime(subscription) {}
    }

    @Test
    func `cancellation removes future work but retains use and reached progress`() async throws {
        let clock = SchedulerTestClock()
        let group = try StreamFixtures.recording("cancel", events: [
            StreamFixtures.value("first", at: .zero),
            StreamFixtures.value("second", at: .seconds(10)),
        ], conclusion: .finished(atTime: .seconds(20)))
        let (execution, dependency) = try StreamFixtures.start([group], clock: clock)
        let journal = SchedulerJournal()
        let subscription = try StreamFixtures.subscribe(dependency, input: "cancel", journal: journal)
        #expect(await journal.take(1) == ["value:first"])
        #expect(try await clock.nextSleep().deadline == .seconds(10))
        #expect(subscription.cancel())
        clock.advance(to: .seconds(30))
        let result = await execution.finish()
        #expect(journal.values == ["value:first"])
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.usage[0].tracks[0].activity == .replay(usedCount: 1, unusedCount: 0))
        #expect(result.usage[0].tracks[0].selectedGroups[0].progressCount == 1)
        #expect(result.usage[0].tracks[0].selectedGroups[0].conclusion == .pending)
    }

    @Test
    func `finish joins claimed delivery and does not schedule a successor after closure`() async throws {
        let clock = SchedulerTestClock()
        let group = try StreamFixtures.recording("finish", events: [
            StreamFixtures.value("first", at: .zero),
            StreamFixtures.value("second", at: .seconds(10)),
        ], conclusion: .finished(atTime: .seconds(20)))
        let (execution, dependency) = try StreamFixtures.start([group], clock: clock)
        let gate = SchedulerDeliveryGate()
        defer { gate.release() }
        let journal = SchedulerJournal()
        let subscription = try dependency.lease.replaySubscription(
            matching: "finish", using: .exactInput(\.input), time: dependency.time,
            scheduling: dependency.scheduling)
        { delivery in
            if case let .value(value) = delivery {
                await gate.suspend()
                journal.append(value)
            }
        }
        await gate.waitForEntry()
        let finish = Task { await execution.finish() }
        while !dependency.time.isClosed {
            await Task.yield()
        }
        gate.release()
        let result = await finish.value
        #expect(journal.values == ["first"])
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.usage[0].tracks[0].selectedGroups[0].progressCount == 1)
        #expect(result.usage[0].tracks[0].selectedGroups[0].conclusion == .pending)
        #expect(!subscription.cancel())
        clock.advance(to: .seconds(30))
        #expect(journal.values == ["first"])
    }

    @Test
    func `cancellation during delivery lets that callback finish and prevents its successor`() async throws {
        let clock = SchedulerTestClock()
        let group = try StreamFixtures.recording("race", events: [
            StreamFixtures.value("first", at: .zero),
            StreamFixtures.value("second", at: .zero),
        ], conclusion: .finished(atTime: nil))
        let (execution, dependency) = try StreamFixtures.start([group], clock: clock)
        let gate = SchedulerDeliveryGate()
        defer { gate.release() }
        let journal = SchedulerJournal()
        let subscription = try dependency.lease.replaySubscription(
            matching: "race", using: .exactInput(\.input), time: dependency.time,
            scheduling: dependency.scheduling)
        { delivery in
            if case let .value(value) = delivery {
                if value == "first" {
                    await gate.suspend()
                }
                journal.append(value)
            }
        }
        await gate.waitForEntry()
        #expect(subscription.cancel())
        gate.release()
        let result = await execution.finish()
        #expect(journal.values == ["first"])
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.usage[0].tracks[0].selectedGroups[0].progressCount == 1)
        #expect(result.usage[0].tracks[0].selectedGroups[0].conclusion == .pending)
    }
}
