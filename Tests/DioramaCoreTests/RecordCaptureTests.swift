@testable import DioramaCore
import Dispatch
import Synchronization
import Testing

enum RecordCaptureFixtures {
    final class Draft: Sendable {
        private let value: Mutex<String?>
        let freezes = Mutex(0)

        init(_ value: String?) {
            self.value = Mutex(value)
        }

        func freeze() -> String? {
            freezes.withLock { $0 += 1 }
            return value.withLock { value in
                let detached = value
                value = nil
                return detached
            }
        }
    }

    static func start(mode: ScenarioMode = .record, values: [String] = []) throws
        -> (ScenarioExecution, HeaderlessSequentialTrackLease<String>)
    {
        let type = ScenarioSystemType("record-capture")
        let id = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: "one"))
        let trackID = TrackID(attachmentID: id, key: TrackKey(rawValue: "records"))
        let track = try SequentialTrack(id: trackID, values: preparedValues(values))
        let attachment = try ScenarioAttachment(id: id).adding(track)
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let lease = try context.lease(for: trackID, preparation: ValuePreparation<String>())
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "capture"), defaultMode: mode,
            systems: [AnyScenarioSystem(system)])
        return try (execution, execution.dependency(system))
    }

    static func values(_ result: ScenarioFinalizationResult, id: TrackID) throws -> [String] {
        let definition = try #require(result.definition)
        let track = try #require(try definition.attachment(for: id.attachmentID.key)?.track(id, as: String.self))
        return track.records.map(\.value)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct RecordCaptureTests {
    private enum Failure: Error { case secret }

    @Test
    func `reservation precedes nested capture and freeze runs once outside the lease lock`() async throws {
        let (execution, lease) = try RecordCaptureFixtures.start()
        let policy = ValuePreparation<String>()
        let first = try lease.beginRecord(preparation: policy, capturing: { identity in
            #expect(identity.sequence == 0)
            _ = try lease.beginRecord(preparation: policy, capturing: { nestedID in
                #expect(nestedID.sequence == 1)
                return RecordCaptureFixtures.Draft("nested")
            }, freeze: { $0.freeze() })
            return RecordCaptureFixtures.Draft("first")
        }, freeze: {
            #expect(lease.isClosed)
            return $0.freeze()
        })
        try lease.record(capturing: { "atomic" }, preparation: policy)
        let result = await execution.finish()
        #expect(try RecordCaptureFixtures.values(result, id: lease.id) == ["first", "nested", "atomic"])
        #expect(result.report.recordingHealth.isHealthy)
        #expect(await execution.finish().usage == result.usage)
        #expect(first.freezes.withLock { $0 } == 1)
    }

    @Test
    func `freeze validates complete prepared values without repeating capture transforms`() async throws {
        let (execution, lease) = try RecordCaptureFixtures.start()
        let counts = Mutex((normalize: 0, validate: 0))
        let policy = ValuePreparation<String>(normalize: { value in
            counts.withLock { $0.normalize += 1 }
            return value
        }, validate: { _ in counts.withLock { $0.validate += 1 } })
        _ = try lease.beginRecord(preparation: policy, capturing: { _ in "prepared" }, freeze: { $0 })
        #expect(await execution.finish().report.recordingHealth.isHealthy)
        #expect(counts.withLock { $0.normalize } == 0)
        #expect(counts.withLock { $0.validate } == 1)
    }

    @Test
    func `failed capture nil freeze and failed validation invalidate the entire candidate`() async throws {
        let (execution, lease) = try RecordCaptureFixtures.start()
        #expect(throws: SequentialOperationFailure.self) {
            try lease.beginRecord(preparation: ValuePreparation<String>(), capturing: { _ -> String in
                throw Failure.secret
            }, freeze: { $0 })
        }
        _ = try lease.beginRecord(preparation: ValuePreparation<String>(), capturing: { _ in 0 }, freeze: { _ in nil })
        let invalid = ValuePreparation<String>(validate: { _ in throw Failure.secret })
        _ = try lease.beginRecord(preparation: invalid, capturing: { _ in "prepared" }, freeze: { $0 })
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(result.usage[0].tracks[0].activity == .record(recordedCount: 0, incompleteCount: 3))
        #expect(result.report.diagnostics.count == 3)
        #expect(!result.rendered().contains("secret"))
    }

    @Test
    func `failed prepared capture retains its original diagnostic once`() async throws {
        let (execution, lease) = try RecordCaptureFixtures.start()
        #expect(throws: SequentialOperationFailure.self) {
            try lease.beginRecord(preparation: ValuePreparation<String>(), capturing: { identity in
                try ValuePreparation<String>().prepare(capturing: { throw Failure.secret },
                                                       purpose: .recording, reporter: lease.reporter,
                                                       context: .record(identity))
            }, freeze: { $0.value })
        }
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.count == 1)
    }

    @Test(arguments: [ScenarioMode.replay, .passthrough])
    func `wrong mode and closed admission do not call factories`(mode: ScenarioMode) async throws {
        let (execution, lease) = try RecordCaptureFixtures.start(mode: mode)
        #expect(throws: SequentialOperationFailure.self) {
            try lease.beginRecord(preparation: ValuePreparation<String>(), capturing: { _ in
                Issue.record("Wrong mode called the factory")
                return "bad"
            }, freeze: { $0 })
        }
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.wrongMode(expected: .record, actual: mode)),
        ])
        #expect(throws: SequentialOperationFailure.self) {
            try lease.beginRecord(preparation: ValuePreparation<String>(), capturing: { _ in
                Issue.record("Closed admission called the factory")
                return "bad"
            }, freeze: { $0 })
        }
        #expect(lease.reporter.postFinishDiagnostics.last?.diagnostic.issue == .lifecycle(.leaseClosed))
    }

    @Test
    func `finish racing slow construction detaches the rejected accumulator exactly once`() async throws {
        let (execution, lease) = try RecordCaptureFixtures.start()
        let entered = AsyncStream<Void>.makeStream()
        let completed = AsyncStream<Bool>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let draft = RecordCaptureFixtures.Draft("late")
        DispatchQueue.global().async {
            let rejected = (try? lease.beginRecord(preparation: ValuePreparation<String>(), capturing: { _ in
                entered.continuation.finish()
                release.wait()
                return draft
            }, freeze: { $0.freeze() })) == nil
            completed.continuation.yield(rejected)
            completed.continuation.finish()
        }
        for await _ in entered.stream {}
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.verification(.recordingNotAdmitted)])
        release.signal()
        for await rejected in completed.stream {
            #expect(rejected)
        }
        #expect(draft.freezes.withLock { $0 } == 1)
        #expect(lease.reporter.postFinishDiagnostics.last?.diagnostic.issue == .lifecycle(.leaseClosed))
        #expect(await execution.finish().report == result.report)
    }

    @Test
    func `closed lease releases accumulator and freeze captures`() async throws {
        let (execution, lease) = try RecordCaptureFixtures.start()
        weak var accumulator: RecordCaptureFixtures.Draft?
        weak var callbackCapture: RecordCaptureFixtures.Draft?
        do {
            let captured = RecordCaptureFixtures.Draft("callback")
            callbackCapture = captured
            accumulator = try lease.beginRecord(preparation: ValuePreparation<String>(), capturing: { _ in
                RecordCaptureFixtures.Draft("record")
            }, freeze: {
                _ = captured.freeze()
                return $0.freeze()
            })
        }
        #expect(accumulator != nil)
        #expect(callbackCapture != nil)
        #expect(await execution.finish().report.recordingHealth.isHealthy)
        #expect(lease.isClosed)
        #expect(accumulator == nil)
        #expect(callbackCapture == nil)
    }
}
