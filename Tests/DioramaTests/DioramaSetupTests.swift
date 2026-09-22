import Diorama
import DioramaCore
import Synchronization
import Testing

struct DioramaSetupTests {
    @Test
    func `scoped execution finalizes its dependency and retains diagnostic identity`() async throws {
        let probe = DioramaSetupProbe()
        let system = try probe.system("a")
        let result = try await Diorama(scenarioID: "setup", mode: .record, systems: system).execute { lease in
            #expect(!lease.isClosed)
            return lease
        }
        #expect(result.loadResult == nil)
        #expect(result.finalization.report.scenarioID.rawValue == "setup")
        #expect(result.body.isClosed)
        #expect(probe.events.withLock { $0.filter { $0 == "cleanup-a" }.count } == 1)
    }

    @Test
    func `no baseline refuses replay while explicit empty content is valid`() async throws {
        let probe = DioramaSetupProbe()
        let system = try probe.system("a")
        let absent = try Diorama(scenarioID: "setup", mode: .replay, systems: system)
        await #expect(throws: ScenarioStartupFailure.self) { try await absent.execute { _ in () } }
        #expect(probe.events.withLock { $0 }.isEmpty)
        let baseline = try ScenarioDefinition(attachments: [system.attachment])
        let empty = try Diorama(definition: baseline, scenarioID: "setup", mode: .replay, systems: system)
        let result = try await empty.execute { _ in () }
        #expect(result.finalization.report.diagnostics.isEmpty)
    }

    @Test
    func `fixed baseline is authoritative and repeated replays have independent consumption`() async throws {
        let probe = DioramaSetupProbe()
        let system = try probe.system("a", values: [99])
        let baseline = try DioramaFixtures.definition(["a"])
        let setup = try Diorama(definition: baseline, scenarioID: "setup", mode: .replay, systems: system)
        let first = try await setup.execute { lease in
            try [lease.claimNext().value, lease.claimNext().value]
        }
        let second = try await setup.execute { lease in try lease.claimNext().value }
        #expect(first.body == [1, 2])
        #expect(second.body == 1)
        #expect(try baseline.attachments[0].track(DioramaFixtures.track("a"), as: Int.self)?.records.count == 2)
    }

    @Test
    func `mixed modes add empty record layout and diagnose unmatched content`() async throws {
        let probe = DioramaSetupProbe()
        let replay = try probe.system("a", allowsUnusedReplayRecords: true).withMode(.replay)
        let record = try probe.system("new", values: [99])
        let baseline = try DioramaFixtures.definition(["a", "omitted"])
        let setup = try Diorama(definition: baseline, scenarioID: "mixed", mode: .record,
                                systems: record, replay)
        let result = try await setup.execute { recording, replaying in
            #expect(recording.mode == .record)
            try recording.append(capturing: { 7 }, preparation: ValuePreparation<Int>())
            return try replaying.claimNext().value
        }
        #expect(result.body == 1)
        #expect(result.finalization.usage.map(\.attachmentID) == [record.attachment.id, replay.attachment.id])
        #expect(result.finalization.usage[0].tracks[0].activity == .record(recordedCount: 1, incompleteCount: 0))
        #expect(result.finalization.usage[1].allowsUnusedReplayRecords)
        #expect(result.finalization.report.diagnostics.map(\.diagnostic.issue) == [
            .baseline(.loadedAttachmentNotConfigured),
        ])
    }

    @Test
    func `declaration errors precede callbacks`() throws {
        let probe = DioramaSetupProbe()
        let system = try probe.system("a")
        #expect(throws: ScenarioDefinitionError.duplicateAttachment(system.attachment.id)) {
            try Diorama(scenarioID: "setup", mode: .record, systems: system, system)
        }
        let otherID = AttachmentID(systemTypeID: SystemTypeID(rawValue: "other"), key: system.attachment.id.key)
        let other = try ScenarioSystem(
            type: ScenarioSystemType(id: otherID.systemTypeID),
            attachment: ScenarioAttachment(id: otherID))
        { _ in
            PreparedSystem { ActivatedSystem(dependency: true, deactivate: {}) }
        }
        #expect(throws: ScenarioDefinitionError.self) {
            try Diorama(scenarioID: "setup", mode: .record, systems: system, other)
        }
        #expect(probe.events.withLock { $0 }.isEmpty)
    }

    @Test
    func `missing replay attachment and incompatible tracks refuse all activation`() async throws {
        let probe = DioramaSetupProbe()
        let first = try probe.system("a")
        let second = try probe.system("b")
        let missing = try Diorama(
            definition: DioramaFixtures.definition(["a"]), scenarioID: "setup", mode: .replay,
            systems: first, second)
        await #expect(throws: ScenarioStartupFailure.self) { try await missing.execute { _, _ in () } }
        #expect(probe.events.withLock { $0 }.isEmpty)
        let invalidTrack = try ScenarioAttachment(id: second.attachment.id).adding(
            SequentialTrack<String>(id: DioramaFixtures.track("b")))
        let incompatible = try Diorama(
            definition: ScenarioDefinition(attachments: [first.attachment, invalidTrack]),
            scenarioID: "setup", mode: .replay, systems: first, second)
        await #expect(throws: ScenarioStartupFailure.self) { try await incompatible.execute { _, _ in () } }
        #expect(probe.events.withLock { $0 } == ["prepare-a", "prepare-b"])
    }

    @Test
    func `no baseline discards declaration content and creates lazy fresh state`() async throws {
        let probe = DioramaSetupProbe()
        let system = try probe.system("a", values: [99])
        let setup = try Diorama(scenarioID: "setup", mode: .record, systems: system)
        #expect(probe.events.withLock { $0 }.isEmpty)
        for _ in 0..<2 {
            let result = try await setup.execute { lease in
                try lease.append(capturing: { 7 }, preparation: ValuePreparation<Int>())
            }
            #expect(result.finalization.usage[0].tracks[0].activity == .record(recordedCount: 1, incompleteCount: 0))
        }
        #expect(probe.events.withLock { $0 } == [
            "prepare-a", "activate-a", "cleanup-a", "prepare-a", "activate-a", "cleanup-a",
        ])
    }
}

final class DioramaSetupProbe: Sendable {
    let events = Mutex<[String]>([])

    func system(
        _ key: String, values: [Int] = [], allowsUnusedReplayRecords: Bool = false)
        throws -> ScenarioSystem<SequentialTrackLease<Int>>
    {
        let attachment = try ScenarioAttachment(id: DioramaFixtures.attachment(key)).adding(
            SequentialTrack(id: DioramaFixtures.track(key), values: preparedValues(values)))
        return try ScenarioSystem(type: DioramaFixtures.type, attachment: attachment,
                                  allowsUnusedReplayRecords: allowsUnusedReplayRecords)
        { [self] context in
            events.withLock { $0.append("prepare-" + key) }
            let lease = try context.lease(for: DioramaFixtures.track(key), preparation: ValuePreparation<Int>())
            return PreparedSystem { [self] in
                events.withLock { $0.append("activate-" + key) }
                return ActivatedSystem(dependency: lease) { [self] in
                    #expect(!Task.isCancelled)
                    events.withLock { $0.append("cleanup-" + key) }
                }
            }
        }
    }
}
