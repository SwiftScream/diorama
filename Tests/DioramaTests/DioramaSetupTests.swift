import Diorama
import DioramaCore
import Synchronization
import Testing

struct DioramaSetupTests {
    @Test
    func `scoped execution finalizes its dependency and retains diagnostic identity`() async throws {
        let probe = DioramaSetupProbe()
        let system = try probe.system("a")
        let result = try await Diorama(scenarioID: "setup", mode: .record, systems: system).execute { _, lease in
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
        await #expect(throws: ScenarioStartupFailure.self) { try await absent.execute { _, _ in () } }
        #expect(probe.events.withLock { $0 }.isEmpty)
        let baseline = try ScenarioDefinition(attachments: [system.attachment])
        let empty = try Diorama(definition: baseline, scenarioID: "setup", mode: .replay, systems: system)
        let result = try await empty.execute { _, _ in () }
        #expect(result.finalization.report.diagnostics.isEmpty)
    }

    @Test
    func `fixed baseline is authoritative and repeated replays have independent consumption`() async throws {
        let probe = DioramaSetupProbe()
        let system = try probe.system("a", values: [99])
        let baseline = try DioramaFixtures.definition(["a"])
        let setup = try Diorama(definition: baseline, scenarioID: "setup", mode: .replay, systems: system)
        let first = try await setup.execute { _, lease in
            try [lease.consumeNext(), lease.consumeNext()]
        }
        let second = try await setup.execute { _, lease in try lease.consumeNext() }
        #expect(first.body == [1, 2])
        #expect(second.body == 1)
        #expect(try baseline.attachments[0].track(DioramaFixtures.track("a"), as: Int.self)?.records.count == 2)
    }

    @Test
    func `mixed modes add empty record layout and diagnose unmatched content`() async throws {
        let probe = DioramaSetupProbe()
        let replay = try probe.system("a", allowsUnclaimedReplayRecords: true).withMode(.replay)
        let record = try probe.system("new", values: [99])
        let baseline = try DioramaFixtures.definition(["a", "omitted"])
        let setup = try Diorama(definition: baseline, scenarioID: "mixed", mode: .record,
                                systems: record, replay)
        let result = try await setup.execute { _, recording, replaying in
            #expect(recording.mode == .record)
            try recording.record(capturing: { 7 }, preparation: ValuePreparation<Int>())
            return try replaying.consumeNext()
        }
        #expect(result.body == 1)
        #expect(result.finalization.usage.map(\.attachmentID) == [record.attachment.id, replay.attachment.id])
        #expect(result.finalization.usage[0].tracks[0].activity == .record(recordedCount: 1, incompleteCount: 0))
        #expect(result.finalization.usage[1].allowsUnclaimedReplayRecords)
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
        let other = try ScenarioSystem(named: system.attachment.id.key.rawValue,
                                       definition: OtherSetupDefinition())
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
        await #expect(throws: ScenarioStartupFailure.self) { try await missing.execute { _, _, _ in () } }
        #expect(probe.events.withLock { $0 }.isEmpty)
        let invalidTrack = try ScenarioAttachment(id: second.attachment.id).adding(
            HeaderlessSequentialTrack<String>(id: DioramaFixtures.track("b")))
        let incompatible = try Diorama(
            definition: ScenarioDefinition(attachments: [first.attachment, invalidTrack]),
            scenarioID: "setup", mode: .replay, systems: first, second)
        do {
            _ = try await incompatible.execute { _, _, _ in () }
            Issue.record("Incompatible typed content activated")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.report.diagnostics.contains {
                $0.diagnostic.issue == .lifecycle(.invalidTrackRequest)
                    && $0.diagnostic.context == .track(DioramaFixtures.track("b"))
            })
        }
        #expect(probe.events.withLock { $0 } == ["prepare-a"])
        // Core rejects the second declaration before its validation hook or any activation.
    }

    @Test
    func `no baseline discards declaration content and creates lazy fresh state`() async throws {
        let probe = DioramaSetupProbe()
        let system = try probe.system("a", values: [99])
        let setup = try Diorama(scenarioID: "setup", mode: .record, systems: system)
        #expect(probe.events.withLock { $0 }.isEmpty)
        for _ in 0..<2 {
            let result = try await setup.execute { _, lease in
                try lease.record(capturing: { 7 }, preparation: ValuePreparation<Int>())
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
        _ key: String, values: [Int] = [], allowsUnclaimedReplayRecords: Bool = false)
        throws -> ScenarioSystem<SetupDependency>
    {
        try ScenarioSystem(named: key, definition: Definition(
            probe: self, key: key, values: SystemTrack("values", values: preparedValues(values))),
        allowsUnclaimedReplayRecords: allowsUnclaimedReplayRecords)
    }

    private struct Definition: SystemDefinition {
        let systemType = DioramaFixtures.type
        let probe: DioramaSetupProbe
        let key: String
        let values: SystemTrack<Int, Void>
        var tracks: [AnySystemTrack] {
            [values.erased]
        }

        func validate(in _: borrowing SystemValidationContext) {
            probe.events.withLock { $0.append("prepare-" + key) }
        }

        func makeRecordState(in context: borrowing SystemStateContext) throws
            -> HeaderlessSequentialTrackLease<Int>
        {
            probe.events.withLock { $0.append("activate-" + key) }
            return try context.lease(for: values)
        }

        func makeReplayState(in context: borrowing SystemStateContext) throws
            -> HeaderlessSequentialTrackLease<Int>
        {
            try makeRecordState(in: context)
        }

        func makeRecordDependency(using runtime: SystemRuntime<HeaderlessSequentialTrackLease<Int>>)
            -> SetupDependency
        {
            SetupDependency(runtime: runtime, mode: .record)
        }

        func makeReplayDependency(using runtime: SystemRuntime<HeaderlessSequentialTrackLease<Int>>)
            -> SetupDependency
        {
            SetupDependency(runtime: runtime, mode: .replay)
        }

        func makePassthroughDependency() throws -> SetupDependency {
            throw ConsumerSetupFailure.unsupported
        }

        func cleanUpRecordState(_: HeaderlessSequentialTrackLease<Int>) {
            #expect(!Task.isCancelled)
            probe.events.withLock { $0.append("cleanup-" + key) }
        }

        func cleanUpReplayState(_ state: HeaderlessSequentialTrackLease<Int>) {
            cleanUpRecordState(state)
        }
    }
}

struct SetupDependency: Sendable {
    let runtime: SystemRuntime<HeaderlessSequentialTrackLease<Int>>
    let mode: ScenarioMode
    var isClosed: Bool {
        runtime.isClosed
    }

    func consumeNext() throws -> Int {
        try runtime.withActiveState { lease, operation in try operation.consumeNext(on: lease) }
    }

    func record(capturing capture: () throws -> Int, preparation: ValuePreparation<Int>) throws {
        _ = try runtime.withActiveState { lease, operation in
            try operation.record(on: lease, capturing: capture, preparation: preparation)
        }
    }
}

private enum ConsumerSetupFailure: Error { case unsupported }

private struct OtherSetupDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("other")
    func makeRecordState(in _: borrowing SystemStateContext) {}
    func makeReplayState(in _: borrowing SystemStateContext) {}
    func makeRecordDependency(using _: SystemRuntime<Void>) -> Bool {
        true
    }

    func makeReplayDependency(using _: SystemRuntime<Void>) -> Bool {
        true
    }

    func makePassthroughDependency() -> Bool {
        true
    }
}
