import DioramaCore
import Synchronization
import Testing

struct ScenarioUsageTests {
    @Test
    func `mixed modes preserve track order and only replay incurs unused obligations`() async throws {
        let replayID = ExecutionFixtures.attachment("replay")
        let first = TrackID(attachmentID: replayID, key: TrackKey(rawValue: "z"))
        let second = TrackID(attachmentID: replayID, key: TrackKey(rawValue: "a"))
        let replay = try ScenarioAttachment(id: replayID)
            .adding(SequentialTrack(id: first, values: preparedValues([11, 12, 13])))
            .adding(SequentialTrack(id: second, values: preparedValues([21])))
        let record = try ScenarioAttachment(id: ExecutionFixtures.attachment("record"), modeOverride: .record)
            .adding(SequentialTrack(id: ExecutionFixtures.track("record"), values: preparedValues([99])))
        let pass = try ScenarioAttachment(id: ExecutionFixtures.attachment("pass"), modeOverride: .passthrough)
            .adding(SequentialTrack(id: ExecutionFixtures.track("pass"), values: preparedValues([99])))
        let definition = try ScenarioDefinition(id: ScenarioID(rawValue: "mixed"), defaultMode: .replay,
                                                attachments: [replay, record, pass])
        let journal = ExecutionFixtures.Journal()
        let replayInstance = ScenarioSystem(attachment: replay) { context in
            // Lease request order deliberately differs from declaration order.
            let secondLease = try context.lease(for: second, preparation: ValuePreparation<Int>())
            let firstLease = try context.lease(for: first, preparation: ValuePreparation<Int>())
            return PreparedSystem { ActivatedSystem(dependency: [firstLease, secondLease], deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(definition: definition, systems: [
            ExecutionFixtures.system("pass", journal: journal), AnyScenarioSystem(replayInstance),
            ExecutionFixtures.system("record", journal: journal),
        ])
        let leases = try execution.dependency(replayInstance)
        #expect(try leases[0].claimNext().value == 11)
        #expect(try leases[1].claimNext().value == 21)
        #expect(throws: SequentialOperationFailure.self) { try leases[1].claimNext() }
        let recording = try execution.dependency(
            DependencyKey<SequentialTrackLease<Int>>(attachmentID: record.id))
        try recording.append(capturing: { 42 }, preparation: ValuePreparation<Int>())
        let result = await execution.finish()
        #expect(result.usage.map(\.attachmentID) == [replay.id, record.id, pass.id])
        #expect(result.usage.map(\.mode) == [.replay, .record, .passthrough])
        #expect(result.usage[0].tracks.map(\.id) == [first, second])
        #expect(result.usage.flatMap(\.tracks).map(\.activity) == [
            .replay(usedCount: 1, unusedCount: 2), .replay(usedCount: 1, unusedCount: 0),
            .record(recordedCount: 1, incompleteCount: 0), .passthrough,
        ])
        #expect(result.evaluate(.allRecordingsUsed).failures == [
            .unusedRecord(RecordIdentity(trackID: first, sequence: 1)),
            .unusedRecord(RecordIdentity(trackID: first, sequence: 2)),
        ])
        #expect(!result.evaluate(.noUnexpectedOperations).isSatisfied)
        #expect(result.evaluate(.allRecordingsUsed, attachments: [record.id.key, pass.id.key]).isSatisfied)
        #expect(await execution.finish() == result)
    }

    @Test
    func `unattached inventory diagnoses once per system while ignored facts stay inspectable`() async throws {
        let missing = ExecutionFixtures.track("missing")
        let other = TrackID(attachmentID: missing.attachmentID, key: TrackKey(rawValue: "other"))
        let ignored = ExecutionFixtures.track("ignored")
        let inventory = try [
            UnattachedTrack(SequentialTrack(id: missing, values: preparedValues([7]))),
            UnattachedTrack(SequentialTrack<Int>(id: ignored)),
            UnattachedTrack(SequentialTrack<Int>(id: other)),
        ]
        let definition = try ScenarioDefinition(id: ScenarioID(rawValue: "inventory"), defaultMode: .replay,
                                                unattachedTracks: inventory,
                                                ignoredAttachments: [ignored.attachmentID.key])
        let notifications = Mutex<[ReportedDiagnostic]>([])
        let execution = try ScenarioExecution.start(definition: definition, systems: [], sink: DiagnosticSink { entry in
            notifications.withLock { $0.append(entry) }
        })
        #expect(execution.reporter.report.diagnostics.map(\.diagnostic.context) == [.attachment(missing.attachmentID)])
        let result = await execution.finish()
        #expect(result.report.diagnostics == notifications.withLock { $0 })
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.verification(.unattachedRecording)])
        #expect(result.usage.map(\.attachmentID) == [missing.attachmentID, ignored.attachmentID])
        #expect(result.usage.map(\.isIgnored) == [false, true])
        #expect(result.usage.allSatisfy { $0.mode == nil })
        #expect(result.usage[0].tracks.map(\.activity) == [.unattached(recordCount: 1), .unattached(recordCount: 0)])
        #expect(result.evaluate(.allRecordingsUsed).failures == [.unattachedTrack(missing), .unattachedTrack(other)])
        #expect(result.evaluate(.allRecordingsUsed, attachments: [ignored.attachmentID.key]).isSatisfied)
        #expect(result.cleanup.isEmpty)
    }

    @Test
    func `ignoring active usage preserves preparation health and operation diagnostics`() async throws {
        let id = ExecutionFixtures.attachment("a")
        let base = try ExecutionFixtures.definition(["a"])
        let definition = try ScenarioDefinition(id: base.id, defaultMode: .replay, attachments: base.attachments,
                                                ignoredAttachments: [id.key])
        let preparations = Mutex(0)
        let instance = ScenarioSystem(attachment: definition.attachments[0]) { context in
            let lease = try context.lease(
                for: ExecutionFixtures.track("a"), preparation: ValuePreparation<Int>(validate: { _ in
                    preparations.withLock { $0 += 1 }
                }))
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: definition,
            systems: [AnyScenarioSystem(instance)])
        let lease = try execution.dependency(instance)
        #expect(throws: SequentialOperationFailure.self) {
            try lease.append(capturing: { 4 }, preparation: ValuePreparation<Int>())
        }
        #expect(lease.report(.system(DiagnosticLabel("unhealthy")), recordingImpact: .invalidatesCandidate))
        let result = await execution.finish()
        #expect(preparations.withLock { $0 } == 2)
        #expect(result.usage[0].tracks[0].unusedRecords.count == 2)
        #expect(result.evaluate(.allRecordingsUsed).isSatisfied)
        #expect(!result.evaluate(.healthyRecording).isSatisfied)
        #expect(!result.evaluate(.noUnexpectedOperations).isSatisfied)
    }

    @Test
    func `inventory validates identity collisions and unknown ignore keys`() throws {
        let track = ExecutionFixtures.track("a")
        let inventory = UnattachedTrack(SequentialTrack<Int>(id: track))
        let incompatible = TrackID(attachmentID: AttachmentID(systemTypeID: SystemTypeID(rawValue: "different"),
                                                              key: track.attachmentID.key), key: track.key)
        #expect(throws: ScenarioDefinitionError.duplicateTrack(track)) {
            try ScenarioDefinition(id: ScenarioID(rawValue: "inventory"), defaultMode: .replay,
                                   unattachedTracks: [inventory, inventory])
        }
        #expect(throws: ScenarioDefinitionError.duplicateAttachment(track.attachmentID)) {
            try ScenarioDefinition(id: ScenarioID(rawValue: "inventory"), defaultMode: .replay,
                                   attachments: [ScenarioAttachment(id: track.attachmentID)],
                                   unattachedTracks: [inventory])
        }
        #expect(throws: ScenarioDefinitionError.incompatibleAttachmentSystem(
            key: track.attachmentID.key, existing: track.attachmentID.systemTypeID,
            proposed: incompatible.attachmentID.systemTypeID))
        {
            try ScenarioDefinition(id: ScenarioID(rawValue: "inventory"), defaultMode: .replay,
                                   unattachedTracks: [
                                       inventory, UnattachedTrack(SequentialTrack<Int>(id: incompatible)),
                                   ])
        }
        #expect(throws: ScenarioDefinitionError.unknownIgnoredAttachment(AttachmentKey(rawValue: "a"))) {
            try ScenarioDefinition(id: ScenarioID(rawValue: "inventory"), defaultMode: .replay,
                                   ignoredAttachments: [AttachmentKey(rawValue: "z"), AttachmentKey(rawValue: "a")])
        }
    }

    @Test
    func `inventory and frozen usage do not retain prepared values`() async throws {
        let releases = Mutex(0)
        let inventory: UnattachedTrack
        do {
            let value = ExecutionFixtures.Probe { releases.withLock { $0 += 1 } }
            inventory = try UnattachedTrack(SequentialTrack(
                id: ExecutionFixtures.track("a"), values: preparedValues([value])))
        }
        #expect(releases.withLock { $0 } == 1)
        let execution = try ScenarioExecution.start(definition: ScenarioDefinition(
            id: ScenarioID(rawValue: "inventory"), defaultMode: .replay, unattachedTracks: [inventory]), systems: [])
        let result = await execution.finish()
        #expect(result.usage[0].tracks[0].activity == .unattached(recordCount: 1))
        #expect(result.evaluate(.allRecordingsUsed).failures == [.unattachedTrack(inventory.id)])
    }
}
