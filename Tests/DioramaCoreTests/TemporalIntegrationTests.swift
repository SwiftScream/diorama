@testable import DioramaCore
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TemporalIntegrationTests {
    @Test
    func `mixed mode shutdown drains record consumption before freezing live capture`() async throws {
        let clock = SchedulerTestClock()
        let (execution, services) = try setup(clock: clock.source)
        let (capture, playback) = services
        #expect(capture.time === playback.time)
        let frozen = Mutex(false)
        let returned = Mutex(false)
        try beginLiveCapture(capture) { frozen.withLock { $0 = true } }
        let first = try playback.records.claim(matching: "first", using: .exactInput { $0 })
        let second = try playback.records.claim(matching: "second", using: .exactInput { $0 })
        let gate = SchedulerDeliveryGate()
        defer { gate.release() }
        let journal = SchedulerJournal()
        let firstHandle = try playback.scheduling.schedule(at: .seconds(1), for: first.record.identity) {
            await gate.suspend()
            #expect(!returned.withLock { $0 })
            #expect(!frozen.withLock { $0 })
            #expect(playback.records.isClosed) // Admission is closed; progress remains writable.
            #expect(first.advance(to: 1))
            #expect(first.markConsumed())
        }
        let secondHandle = try playback.scheduling.schedule(at: .seconds(1), for: second.record.identity) {
            #expect(second.markConsumed())
            journal.append("second")
        }
        _ = try await clock.nextSleep()
        clock.advance(to: .seconds(1))
        await gate.waitForEntry()
        #expect(await journal.take(1) == ["second"])
        let pending = try pendingCallback(playback, record: second.record.identity)
        let staleWait = try await clock.nextSleep()
        #expect(staleWait.deadline == .seconds(5))
        let finish = Task {
            let result = await execution.finish()
            returned.withLock { $0 = true }
            return result
        }
        #expect(try await clock.nextCancellation() == .seconds(5))
        #expect(!returned.withLock { $0 })
        #expect(!frozen.withLock { $0 })
        #expect(firstHandle.registration.phase == .claimed)
        #expect(pending.registration.phase == .canceled)
        #expect(!capture.records.report(.system(DiagnosticLabel("admission-closed"))))
        gate.release()
        let result = await finish.value
        #expect(frozen.withLock { $0 })
        try verifyResult(result, capture: capture, claim: first, handles: (firstHandle, secondHandle), clock: clock)
        staleWait.resume.finish()
        clock.advance(to: .seconds(10))
        #expect(await execution.finish().usage == result.usage)
        #expect(journal.values == ["second"])
    }

    private func verifyResult(_ result: ScenarioFinalizationResult, capture: Services, claim: ReplayClaim<String>,
                              handles: (ScheduledItemHandle, ScheduledItemHandle), clock: SchedulerTestClock) throws
    {
        #expect(result.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(result.usage[1].tracks[0].claimedRecords.map(\.progressCount) == [1, 0])
        #expect(handles.0.registration.phase == .completed)
        #expect(handles.1.registration.phase == .completed)
        #expect(!claim.markConsumed())
        #expect(clock.activeWaits == 0)
        let recorded = try #require(try result.definition?.attachment(for: capture.records.id.attachmentID.key)?
            .track(capture.records.id, as: String.self))
        #expect(recorded.records.map(\.value) == ["live-value"])
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
    }

    private func beginLiveCapture(_ capture: Services, onFreeze: @escaping @Sendable () -> Void) throws {
        _ = try capture.records.beginRecord(preparation: ValuePreparation<String>(), capturing: { _ in
            try ValuePreparation<String>().prepare(capturing: { "live-value" },
                                                   purpose: .recording, reporter: capture.records.reporter)
        }, freeze: { prepared in
            onFreeze()
            return prepared.value
        })
    }

    private func pendingCallback(_ playback: Services, record: RecordIdentity) throws -> ScheduledItemHandle {
        try playback.scheduling.schedule(at: .seconds(5), for: record) {
            Issue.record("Pending callback must not survive shutdown")
        }
    }

    private func setup(clock: ExecutionClock) throws -> (ScenarioExecution, (Services, Services)) {
        let live = try system(key: "live", values: []).withMode(.record)
        let replay = try system(key: "replay", values: ["first", "second"])
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [live.attachment, replay.attachment]),
            scenarioID: ScenarioID(rawValue: "mixed-shutdown"), defaultMode: .replay,
            systems: [AnyScenarioSystem(replay), AnyScenarioSystem(live)], clock: clock)
        return try (execution, (execution.dependency(live), execution.dependency(replay)))
    }

    private struct Services: Sendable {
        let records: HeaderlessSequentialTrackLease<String>
        let time: ExecutionTime
        let scheduling: SchedulingLease
    }

    private func system(key: String, values: [String]) throws -> ScenarioSystem<Services> {
        let type = ScenarioSystemType("test.temporal-integration")
        let id = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: key))
        let trackID = TrackID(attachmentID: id, key: TrackKey(rawValue: "records"))
        let track = try HeaderlessSequentialTrack(id: trackID, values: preparedValues(values))
        let attachment = try ScenarioAttachment(id: id).adding(track)
        return try ScenarioSystem(type: type, attachment: attachment) { context in
            let records = try context.lease(for: trackID, preparation: ValuePreparation<String>())
            let services = Services(records: records, time: context.time, scheduling: context.scheduling)
            return PreparedSystem { ActivatedSystem(dependency: services, deactivate: {}) }
        }
    }
}
