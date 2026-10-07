@testable import DioramaCore
import Dispatch
import Synchronization
import Testing

enum RecordingMergeFixtures {
    enum Failure: Error { case secret }

    static func start(
        mode: ScenarioMode = .record,
        merge: RecordingMerge<Int, Int>? = nil,
        valuePolicy: ValuePreparation<Int> = .init(),
        headerPolicy: ValuePreparation<Int> = .init(),
        failsActivation: Bool = false) throws -> (ScenarioExecution, SequentialTrackLease<Int, Int>)
    {
        let type = ScenarioSystemType("test.recording-merge")
        let id = TrackID(attachmentID: AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: "one")),
                         key: TrackKey(rawValue: "values"))
        let track = try SequentialTrack(id: id, header: ValuePreparation<Int>().admitPrepared(10),
                                        values: preparedValues([1, 2]))
        let attachment = try ScenarioAttachment(id: id.attachmentID).adding(track)
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let lease = try context.lease(for: id, preparation: valuePolicy, headerPreparation: headerPolicy,
                                          mergeRecording: merge)
            return PreparedSystem {
                if failsActivation {
                    throw Failure.secret
                }
                return ActivatedSystem(dependency: lease, deactivate: {})
            }
        }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "merge"), defaultMode: mode, systems: [AnyScenarioSystem(system)])
        return try (execution, execution.dependency(system))
    }

    static func track(_ result: ScenarioFinalizationResult, id: TrackID) throws -> SequentialTrack<Int, Int> {
        let definition = try #require(result.definition)
        return try #require(try definition.attachment(for: id.attachmentID.key)?.track(
            id, as: Int.self, header: Int.self))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct RecordingMergeTests {
    @Test
    func `merge receives typed baseline and fresh headers and runs once outside state locks`() async throws {
        let calls = Mutex(0)
        let reference = Mutex<SequentialTrackLease<Int, Int>?>(nil)
        defer { reference.withLock { $0 = nil } }
        let (execution, lease) = try RecordingMergeFixtures.start(merge: { baseline, fresh in
            calls.withLock { $0 += 1 }
            #expect(baseline.header == 10)
            #expect(baseline.records.map(\.value) == [1, 2])
            #expect(fresh.header == 20)
            #expect(fresh.records.map(\.value) == [7, 8])
            #expect(reference.withLock { $0?.baselineHeader() } == nil)
            let values = try preparedValues([baseline.records[0].value, fresh.records[1].value])
            return try SequentialTrack(id: fresh.id, header: ValuePreparation<Int>().admitPrepared(baseline.header),
                                       values: values)
        })
        reference.withLock { $0 = lease }
        try lease.setHeader(capturing: { 20 }, preparation: ValuePreparation<Int>())
        try lease.record(capturing: { 7 }, preparation: ValuePreparation<Int>())
        try lease.record(capturing: { 8 }, preparation: ValuePreparation<Int>())
        let results = await withTaskGroup(
            of: ScenarioFinalizationResult.self,
            returning: [ScenarioFinalizationResult].self)
        { group in
            for _ in 0..<12 {
                group.addTask { await execution.finish() }
            }
            var results: [ScenarioFinalizationResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        #expect(results.count == 12)
        #expect(calls.withLock { $0 } == 1)
        for result in results {
            let track = try RecordingMergeFixtures.track(result, id: lease.id)
            #expect(track.header == 10)
            #expect(track.records.map(\.value) == [1, 8])
            #expect(track.records.map(\.identity.sequence) == [0, 1])
            #expect(result.report.diagnostics.isEmpty)
            #expect(result.usage[0].tracks[0].activity == .record(recordedCount: 2, incompleteCount: 0))
        }
    }

    @Test
    func `empty fresh content still receives merge and validation omits capture transforms`() async throws {
        let transformations = Mutex(0)
        let calls = Mutex(0)
        let policy = ValuePreparation<Int>(normalize: { value in
            transformations.withLock { $0 += 1 }
            return value
        })
        let (execution, lease) = try RecordingMergeFixtures.start(merge: { baseline, fresh in
            calls.withLock { $0 += 1 }
            #expect(fresh.records.isEmpty)
            return try SequentialTrack(id: fresh.id, header: ValuePreparation<Int>().admitPrepared(baseline.header + 1))
        }, valuePolicy: policy, headerPolicy: policy)
        let result = await execution.finish()
        #expect(try RecordingMergeFixtures.track(result, id: lease.id).header == 11)
        #expect(calls.withLock { $0 } == 1)
        #expect(transformations.withLock { $0 } == 0)
        #expect(result.report.recordingHealth.isHealthy)
    }

    @Test
    func `merged values are validated without transforming prepared observations again`() async throws {
        let transformations = Mutex(0)
        let policy = ValuePreparation<Int>(redact: { _ in
            transformations.withLock { $0 += 1 }
            return 3
        })
        let (execution, lease) = try RecordingMergeFixtures.start(merge: { _, fresh in fresh }, valuePolicy: policy)
        try lease.record(capturing: { 42 }, preparation: policy)
        let result = await execution.finish()
        #expect(try RecordingMergeFixtures.track(result, id: lease.id).records.map(\.value) == [3])
        #expect(transformations.withLock { $0 } == 1)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test(arguments: [ScenarioMode.replay, .passthrough])
    func `non recording modes preserve baseline and never run the merge`(mode: ScenarioMode) async throws {
        let (execution, lease) = try RecordingMergeFixtures.start(mode: mode, merge: { _, _ in
            Issue.record("Non-recording execution ran the merge")
            throw RecordingMergeFixtures.Failure.secret
        })
        let result = await execution.finish()
        let track = try RecordingMergeFixtures.track(result, id: lease.id)
        #expect(track.header == 10)
        #expect(track.records.map(\.value) == [1, 2])
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test(arguments: [false, true])
    func `unhealthy value or header capture does not merge a partial track`(failsHeader: Bool) async throws {
        let (execution, lease) = try RecordingMergeFixtures.start(merge: { _, _ in
            Issue.record("Unhealthy capture reached the merge")
            throw RecordingMergeFixtures.Failure.secret
        })
        let policy = ValuePreparation<Int>(validate: { _ in throw RecordingMergeFixtures.Failure.secret })
        if failsHeader {
            #expect(throws: SequentialOperationFailure.self) {
                try lease.setHeader(capturing: { 42 }, preparation: policy)
            }
            // A later good header must not hide the earlier unhealthy attempt.
            try lease.setHeader(capturing: { 20 }, preparation: ValuePreparation<Int>())
        } else {
            #expect(throws: SequentialOperationFailure.self) {
                try lease.record(capturing: { 42 }, preparation: policy)
            }
        }
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.preparationFailed(.validation)])
    }

    @Test
    func `unfinished header capture skips merge and late completion cannot change the report`() async throws {
        let (execution, lease) = try RecordingMergeFixtures.start(merge: { _, _ in
            Issue.record("Unfinished capture reached the merge")
            throw RecordingMergeFixtures.Failure.secret
        })
        let entered = AsyncStream<Void>.makeStream()
        let completed = AsyncStream<SequentialOperationFailure?>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue(label: "diorama.merge-header-race").async {
            let failure: SequentialOperationFailure?
            do throws(SequentialOperationFailure) {
                try lease.setHeader(capturing: {
                    entered.continuation.finish()
                    release.wait()
                    return 20
                }, preparation: ValuePreparation<Int>())
                failure = nil
            } catch { failure = error }
            completed.continuation.yield(failure)
            completed.continuation.finish()
        }
        for await _ in entered.stream {}
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.verification(.recordingNotAdmitted)])
        release.signal()
        for await failure in completed.stream {
            #expect(failure?.diagnostic.issue == .lifecycle(.leaseClosed))
        }
        #expect(await execution.finish().report == result.report)
    }

    @Test
    func `startup rollback releases the policy without invoking merge`() throws {
        #expect(throws: ScenarioStartupFailure.self) {
            _ = try RecordingMergeFixtures.start(merge: { _, _ in
                Issue.record("Startup rollback invoked the merge")
                throw RecordingMergeFixtures.Failure.secret
            }, failsActivation: true)
        }
    }

    @Test(arguments: [false, true])
    func `throwing merge or foreign track identity invalidates the complete candidate safely`(
        foreignIdentity: Bool) async throws
    {
        let (execution, lease) = try RecordingMergeFixtures.start(merge: { baseline, _ in
            guard foreignIdentity else { throw RecordingMergeFixtures.Failure.secret }
            let foreign = TrackID(attachmentID: baseline.id.attachmentID, key: TrackKey(rawValue: "foreign"))
            return try SequentialTrack(id: foreign, header: ValuePreparation<Int>().admitPrepared(10))
        })
        try lease.record(capturing: { 7 }, preparation: ValuePreparation<Int>())
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.verification(.recordingMergeFailed)])
        #expect(result.report.diagnostics.map(\.diagnostic.context) == [.track(lease.id)])
        #expect(!result.rendered().contains("secret"))
        #expect(result.rendered().contains("recording-merge-failed"))
    }

    @Test(arguments: [false, true])
    func `merged values and headers receive the setup validation policy`(invalidHeader: Bool) async throws {
        let policy = ValuePreparation<Int>(validate: { value in
            if value > 50 {
                throw RecordingMergeFixtures.Failure.secret
            }
        })
        let (execution, lease) = try RecordingMergeFixtures.start(merge: { _, fresh in
            try SequentialTrack(id: fresh.id, header: ValuePreparation<Int>().admitPrepared(invalidHeader ? 100 : 10),
                                values: preparedValues([invalidHeader ? 3 : 100]))
        }, valuePolicy: policy, headerPolicy: policy)
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.preparationFailed(.validation)])
        let context: DiagnosticContext = invalidHeader ? .track(lease.id)
            : .record(RecordIdentity(trackID: lease.id, sequence: 0))
        #expect(result.report.diagnostics.map(\.diagnostic.context) == [context])
        #expect(result.report.recordingHealth.failures.count == 1)
    }

    @Test(arguments: [false, true])
    func `merge callback captures are released outside state locks even after unhealthy capture`(
        failsCapture: Bool) async throws
    {
        let released = Mutex(0)
        let reference = Mutex<SequentialTrackLease<Int, Int>?>(nil)
        defer { reference.withLock { $0 = nil } }
        var probe: ReleaseProbe? = ReleaseProbe {
            #expect(reference.withLock { $0?.baselineHeader() } == nil)
            released.withLock { $0 += 1 }
        }
        weak let weakProbe = probe
        let (execution, lease) = try RecordingMergeFixtures.start(merge: { [probe] _, fresh in
            withExtendedLifetime(probe) {}
            return fresh
        })
        reference.withLock { $0 = lease }
        probe = nil
        #expect(weakProbe != nil)
        if failsCapture {
            #expect(throws: SequentialOperationFailure.self) {
                try lease.record(capturing: { throw RecordingMergeFixtures.Failure.secret },
                                 preparation: ValuePreparation<Int>())
            }
        }
        _ = await execution.finish()
        #expect(weakProbe == nil)
        #expect(released.withLock { $0 } == 1)
    }

    private final class ReleaseProbe: Sendable {
        let onRelease: @Sendable () -> Void

        init(onRelease: @escaping @Sendable () -> Void) {
            self.onRelease = onRelease
        }

        deinit { onRelease() }
    }
}
