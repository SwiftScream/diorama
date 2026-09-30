import DioramaCore
import Testing

struct SequentialStreamConsumerTests {
    @Test
    func `public consumer replays one claimed subscription through its terminal event`() async throws {
        typealias Recording = SubscriptionRecording<String, Int, String>
        let type = ScenarioSystemType("consumer.stream")
        let attachmentID = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: "one"))
        let trackID = TrackID(attachmentID: attachmentID, key: TrackKey(rawValue: "subscriptions"))
        let recording = try Recording(input: "updates", events: [
            .delivered(LifecycleMoment(offset: .zero, value: 1)),
            .reported(LifecycleMoment(offset: .zero, value: "temporary")),
            .delivered(LifecycleMoment(offset: .zero, value: 2)),
        ], conclusion: .finished(atTime: nil))
        let policy = ValuePreparation<Recording>()
        let attachment = try ScenarioAttachment(id: attachmentID)
            .adding(SequentialTrack(id: trackID, values: [policy.admitPrepared(recording)]))
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let lease = try context.lease(for: trackID, preparation: policy)
            let dependency = (lease: lease, time: context.time, scheduling: context.scheduling)
            return PreparedSystem { ActivatedSystem(dependency: dependency, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "consumer-stream"), defaultMode: .replay,
            systems: [AnyScenarioSystem(system)])
        let dependency = try execution.dependency(system)
        let delivered = AsyncStream<String>.makeStream()
        let subscription = try dependency.lease.replaySubscription(
            matching: "updates", using: .exactInput(\.input), time: dependency.time,
            scheduling: dependency.scheduling)
        { event in
            switch event {
            case let .value(value): delivered.continuation.yield("value:\(value)")
            case let .nonterminalFailure(error): delivered.continuation.yield("error:\(error)")
            case .finished: delivered.continuation.yield("finished")
            case let .failed(error): delivered.continuation.yield("failed:\(error)")
            }
        }
        var iterator = delivered.stream.makeAsyncIterator()
        var events: [String] = []
        for _ in 0..<4 {
            try events.append(#require(await iterator.next()))
        }
        #expect(events == ["value:1", "error:temporary", "value:2", "finished"])
        let result = await execution.finish()
        #expect(!subscription.cancel())
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.evaluate(.allSelectedRecordingsCompleted).isSatisfied)
        #expect(result.usage[0].tracks[0].selectedGroups[0].progressCount == 3)
    }
}
