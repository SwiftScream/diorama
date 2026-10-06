import DioramaCore
import Dispatch
import Testing

struct SequentialTrackHeaderTests {
    @Test
    func `typed header travels with its track through recording and replay`() async throws {
        let type = ScenarioSystemType("header-example")
        let id = TrackID(
            attachmentID: AttachmentID(
                systemTypeID: type.id, key: AttachmentKey(rawValue: "clock")),
            key: TrackKey(rawValue: "values"))
        let preparation = ValuePreparation<Int>()
        let baseline = try ScenarioDefinition(attachments: [
            ScenarioAttachment(id: id.attachmentID).adding(
                SequentialTrack(
                    id: id, header: preparation.admitPrepared(660),
                    values: [preparation.admitPrepared(1)])),
        ])
        let system = try ScenarioSystem(type: type, attachment: baseline.attachments[0]) { context in
            let lease = try context.lease(
                for: id, preparation: preparation, headerPreparation: preparation)
            return PreparedSystem {
                ActivatedSystem(dependency: lease, deactivate: {})
            }
        }

        let recording = try ScenarioExecution.start(
            definition: baseline, scenarioID: ScenarioID(rawValue: "header-record"),
            defaultMode: .record, systems: [AnyScenarioSystem(system)])
        let recordingLease = try recording.dependency(system)
        #expect(recordingLease.baselineHeader() == 660)
        try recordingLease.setHeader(capturing: { 120 }, preparation: preparation)
        try recordingLease.setHeader(capturing: { 240 }, preparation: preparation)
        try recordingLease.record(capturing: { 2 }, preparation: preparation)
        let result = await recording.finish()
        let candidate = try #require(result.definition)
        let recordedTrack = try #require(try candidate.attachments[0].track(id, as: Int.self, header: Int.self))
        #expect(recordedTrack.header == 240)
        #expect(recordedTrack.records.map(\.value) == [2])
        #expect(throws: ScenarioDefinitionError.incompatibleTrackType(id)) {
            _ = try candidate.attachments[0].track(id, as: Int.self)
        }
        #expect(try baseline.attachments[0].track(id, as: Int.self, header: Int.self)?.header == 660)

        let replay = try ScenarioExecution.start(
            definition: candidate, scenarioID: ScenarioID(rawValue: "header-replay"),
            defaultMode: .replay, systems: [AnyScenarioSystem(system)])
        let replayLease = try replay.dependency(system)
        #expect(replayLease.baselineHeader() == 240)
        #expect(try replayLease.claimNext().value == 2)
        #expect(await replay.finish().report.diagnostics.isEmpty)

        let emptied = candidate.removingRecords()
        let emptyTrack = try #require(try emptied.attachments[0].track(id, as: Int.self, header: Int.self))
        #expect(emptyTrack.records.isEmpty)
        #expect(emptyTrack.header == 240)
    }

    @Test
    func `empty recording retains its required header`() async throws {
        let type = ScenarioSystemType("empty-header")
        let id = TrackID(
            attachmentID: AttachmentID(
                systemTypeID: type.id, key: AttachmentKey(rawValue: "clock")),
            key: TrackKey(rawValue: "values"))
        let preparation = ValuePreparation<Int>()
        let attachment = try ScenarioAttachment(id: id.attachmentID).adding(
            SequentialTrack<Int, Int>(id: id, header: preparation.admitPrepared(660)))
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let lease = try context.lease(
                for: id, preparation: preparation, headerPreparation: preparation)
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "empty-header-record"), defaultMode: .record,
            systems: [AnyScenarioSystem(system)])
        let candidate = try #require(await execution.finish().definition)
        let track = try #require(try candidate.attachments[0].track(id, as: Int.self, header: Int.self))
        #expect(track.records.isEmpty)
        #expect(track.header == 660)
    }

    @Test
    func `non equatable header records and replays`() async throws {
        let type = ScenarioSystemType("non-equatable-header")
        let id = TrackID(
            attachmentID: AttachmentID(
                systemTypeID: type.id, key: AttachmentKey(rawValue: "clock")),
            key: TrackKey(rawValue: "values"))
        let headerPreparation = ValuePreparation<NonEquatableHeader>()
        let attachment = try ScenarioAttachment(id: id.attachmentID).adding(
            SequentialTrack<Int, NonEquatableHeader>(
                id: id, header: headerPreparation.admitPrepared(NonEquatableHeader(offset: 660))))
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let lease = try context.lease(
                for: id, preparation: ValuePreparation<Int>(), headerPreparation: headerPreparation)
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let recording = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "non-equatable-record"), defaultMode: .record,
            systems: [AnyScenarioSystem(system)])
        let lease = try recording.dependency(system)
        #expect(lease.baselineHeader()?.offset == 660)
        try lease.setHeader(capturing: { NonEquatableHeader(offset: 120) }, preparation: headerPreparation)
        let candidate = try #require(await recording.finish().definition)
        let track = try #require(try candidate.attachments[0].track(
            id, as: Int.self, header: NonEquatableHeader.self))
        #expect(track.header.offset == 120)

        let replay = try ScenarioExecution.start(
            definition: candidate, scenarioID: ScenarioID(rawValue: "non-equatable-replay"),
            defaultMode: .replay, systems: [AnyScenarioSystem(system)])
        #expect(try replay.dependency(system).baselineHeader()?.offset == 120)
        #expect(await replay.finish().report.diagnostics.isEmpty)
    }

    @Test
    func `failed header preparation invalidates the candidate despite a later replacement`() async throws {
        let type = ScenarioSystemType("header-example")
        let id = TrackID(
            attachmentID: AttachmentID(
                systemTypeID: type.id, key: AttachmentKey(rawValue: "clock")),
            key: TrackKey(rawValue: "values"))
        let attachment = try ScenarioAttachment(id: id.attachmentID).adding(
            SequentialTrack<Int, Int>(id: id, header: ValuePreparation<Int>().admitPrepared(660)))
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let lease = try context.lease(
                for: id, preparation: ValuePreparation<Int>(),
                headerPreparation: ValuePreparation<Int>())
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "header-failure"), defaultMode: .record,
            systems: [AnyScenarioSystem(system)])
        let lease = try execution.dependency(system)
        #expect(throws: SequentialOperationFailure.self) {
            try lease.setHeader(capturing: { 5 }, preparation: ValuePreparation<Int>(validate: { _ in
                throw HeaderError()
            }))
        }
        try lease.setHeader(capturing: { 6 }, preparation: ValuePreparation<Int>())
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(result.report.diagnostics.contains {
            $0.diagnostic.issue == .preparationFailed(.validation)
        })
    }

    @Test(arguments: [false, true])
    func `later header call wins when earlier capture completes last`(laterFails: Bool) async throws {
        let type = ScenarioSystemType("overlapping-header")
        let id = TrackID(
            attachmentID: AttachmentID(
                systemTypeID: type.id, key: AttachmentKey(rawValue: "clock")),
            key: TrackKey(rawValue: "values"))
        let preparation = ValuePreparation<Int>()
        let attachment = try ScenarioAttachment(id: id.attachmentID).adding(
            SequentialTrack<Int, Int>(id: id, header: preparation.admitPrepared(660)))
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let lease = try context.lease(
                for: id, preparation: preparation, headerPreparation: preparation)
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "overlapping-header"), defaultMode: .record,
            systems: [AnyScenarioSystem(system)])
        let lease = try execution.dependency(system)
        let gate = HeaderCaptureGate()
        defer { gate.release() }
        let earlier = blockedHeaderCall(lease: lease, gate: gate, preparation: preparation)
        await gate.waitForEntry()
        if laterFails {
            #expect(throws: SequentialOperationFailure.self) {
                try lease.setHeader(capturing: { 200 }, preparation: ValuePreparation<Int>(validate: { _ in
                    throw HeaderError()
                }))
            }
        } else {
            try lease.setHeader(capturing: { 200 }, preparation: preparation)
        }
        gate.release()
        #expect(await earlier.value == nil)
        let result = await execution.finish()
        if laterFails {
            #expect(result.definition == nil)
            #expect(result.report.recordingHealth.failures.map(\.diagnostic.issue) == [
                .preparationFailed(.validation),
            ])
        } else {
            let candidate = try #require(result.definition)
            #expect(try candidate.attachments[0].track(id, as: Int.self, header: Int.self)?.header == 200)
            #expect(result.report.diagnostics.isEmpty)
        }
    }

    @Test
    func `finish rejects a header recording with a superseded call still pending`() async throws {
        let type = ScenarioSystemType("unfinished-header")
        let id = TrackID(
            attachmentID: AttachmentID(
                systemTypeID: type.id, key: AttachmentKey(rawValue: "clock")),
            key: TrackKey(rawValue: "values"))
        let preparation = ValuePreparation<Int>()
        let attachment = try ScenarioAttachment(id: id.attachmentID).adding(
            SequentialTrack<Int, Int>(id: id, header: preparation.admitPrepared(660)))
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            let lease = try context.lease(
                for: id, preparation: preparation, headerPreparation: preparation)
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "unfinished-header"), defaultMode: .record,
            systems: [AnyScenarioSystem(system)])
        let lease = try execution.dependency(system)
        let gate = HeaderCaptureGate()
        defer { gate.release() }
        let earlier = blockedHeaderCall(lease: lease, gate: gate, preparation: preparation)
        await gate.waitForEntry()
        try lease.setHeader(capturing: { 200 }, preparation: preparation)
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.recordingHealth.failures.map(\.diagnostic.issue) == [
            .verification(.recordingNotAdmitted),
        ])
        gate.release()
        #expect(await earlier.value?.diagnostic.issue == .lifecycle(.leaseClosed))
    }

    private func blockedHeaderCall(
        lease: SequentialTrackLease<Int, Int>, gate: HeaderCaptureGate,
        preparation: ValuePreparation<Int>) -> Task<SequentialOperationFailure?, Never>
    {
        Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let failure: SequentialOperationFailure?
                    do {
                        try lease.setHeader(capturing: { gate.enter(); return 100 }, preparation: preparation)
                        failure = nil
                    } catch {
                        failure = error as? SequentialOperationFailure
                    }
                    continuation.resume(returning: failure)
                }
            }
        }
    }

    private struct HeaderError: Error {}

    private struct NonEquatableHeader: Sendable {
        let offset: Int
    }
}

private final class HeaderCaptureGate: Sendable {
    private let entry = AsyncStream<Void>.makeStream()
    private let semaphore = DispatchSemaphore(value: 0)

    func enter() {
        entry.continuation.yield(())
        #expect(semaphore.wait(timeout: .now() + 10) == .success)
    }

    func waitForEntry() async {
        for await _ in entry.stream {
            return
        }
    }

    func release() {
        semaphore.signal()
    }
}
