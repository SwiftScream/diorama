@testable import DioramaCore
import Synchronization
import Testing

private enum SelectionFixtures {
    struct Record: Sendable {
        enum Outcome: Sendable, Equatable {
            case returned(String)
            case open
        }

        let input: String
        let outcome: Outcome
    }

    static let type = ScenarioSystemType("selection")

    static func group(_ input: String, output: String? = nil) throws -> Record {
        Record(input: input, outcome: output.map(Record.Outcome.returned) ?? .open)
    }

    static func start(_ groups: [Record], key: String = "one", allowsUnused: Bool = false,
                      mode: ScenarioMode = .replay)
        throws -> (ScenarioExecution, HeaderlessSequentialTrackLease<Record>)
    {
        let attachmentID = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: key))
        let trackID = TrackID(attachmentID: attachmentID, key: TrackKey(rawValue: "groups"))
        let policy = ValuePreparation<Record>()
        let values = try groups.map { try policy.admitPrepared($0) }
        let attachment = try ScenarioAttachment(id: attachmentID)
            .adding(SequentialTrack(id: trackID, values: values))
        let system = try ScenarioSystem(type: type, attachment: attachment,
                                        allowsUnclaimedReplayRecords: allowsUnused)
        { context in
            let lease = try context.lease(for: trackID, preparation: policy)
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "selection"), defaultMode: mode,
            systems: [AnyScenarioSystem(system)])
        return try (execution, execution.dependency(system))
    }

    static var exact: ReplaySelector<String, Record> {
        .exactInput(\.input, differences: { _, _ in [DiagnosticLabel("input")] })
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ReplaySelectionTests {
    @Test
    func `reordered distinct calls and repeated equivalents claim whole records in recorded order`() async throws {
        let groups = try [
            SelectionFixtures.group("repeat", output: "first"),
            SelectionFixtures.group("distinct", output: "other"),
            SelectionFixtures.group("repeat", output: "second"),
            SelectionFixtures.group("open"),
        ]
        let (execution, lease) = try SelectionFixtures.start(groups)
        let trackID = lease.id
        let distinct = try lease.claim(matching: "distinct", using: SelectionFixtures.exact)
        let first = try lease.claim(matching: "repeat", using: SelectionFixtures.exact)
        let second = try lease.claim(matching: "repeat", using: SelectionFixtures.exact)
        let open = try lease.claim(matching: "open", using: SelectionFixtures.exact)
        #expect(distinct.record.identity.sequence == 1)
        #expect(first.record.identity.sequence == 0)
        #expect(second.record.identity.sequence == 2)
        #expect(open.record.identity.sequence == 3)
        #expect(first.record.value.outcome == .returned("first"))
        #expect(second.record.value.outcome == .returned("second"))
        #expect(distinct.advance(to: 2))
        #expect(distinct.markConsumed())
        #expect(first.advance(to: 1))
        #expect(first.advance(to: 1))
        #expect(second.markConsumed())
        #expect(open.markConsumed())
        let result = await execution.finish()
        let usage = result.usage[0].tracks[0]
        #expect(usage.activity == .replay(claimedCount: 4, unclaimedCount: 0))
        #expect(usage.unclaimedRecords.isEmpty)
        #expect(usage.claimedRecords.map(\.identity.sequence) == [0, 1, 2, 3])
        #expect(usage.claimedRecords.map(\.progressCount) == [1, 2, 0, 0])
        #expect(usage.claimedRecords.map(\.isConsumed) == [false, true, true, true])
        #expect(result.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(result.evaluate(.allClaimedRecordsConsumed).failures == [
            .unconsumedRecord(RecordIdentity(trackID: trackID, sequence: 0)),
        ])
        let rendered = result.rendered()
        #expect(rendered.contains("Claimed record 0 progress=1 unconsumed"))
        #expect(rendered.contains("Claimed record 1 progress=2 consumed"))
        #expect(rendered.contains("Claimed record 3 progress=0 consumed"))
        #expect(!first.advance(to: 3))
        #expect(!first.markConsumed())
        #expect(await execution.finish().usage == result.usage)
    }

    @Test(arguments: [false, true])
    func `open recorded behavior requires explicit consumption acknowledgement`(consume: Bool) async throws {
        let (execution, lease) = try SelectionFixtures.start([SelectionFixtures.group("open")])
        let claim = try lease.claim(matching: "open", using: SelectionFixtures.exact)
        // The domain reaches two recorded observations, then its open horizon.
        #expect(claim.advance(to: 2))
        #expect(claim.advance(to: 1)) // Progress cannot move backward.
        if consume {
            #expect(claim.markConsumed())
            #expect(claim.markConsumed()) // Acknowledgement is idempotent.
            #expect(!claim.advance(to: 3))
        }
        let result = await execution.finish()
        let usage = try #require(result.usage[0].tracks[0].claimedRecords.first)
        #expect(usage.progressCount == 2)
        #expect(usage.isConsumed == consume)
        #expect(result.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(result.evaluate(.allClaimedRecordsConsumed).isSatisfied == consume)
        #expect(claim.record.value.outcome == .open) // Consumption does not invent termination.
        #expect(!claim.markConsumed())
        #expect(await execution.finish().usage == result.usage)
    }

    @Test
    func `selection failures stay distinct and do not consume records`() async throws {
        let (execution, lease) = try SelectionFixtures.start([
            SelectionFixtures.group("same", output: "first"),
            SelectionFixtures.group("same", output: "second"),
        ])
        let trackID = lease.id
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claim(matching: "absent", using: SelectionFixtures.exact)
        }
        let ambiguous: ReplaySelector<String, SelectionFixtures.Record> = .init(
            rule: DiagnosticLabel("ambiguous"))
        { _, records in
            .ambiguous(records.map(\.identity))
        }
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claim(matching: "same", using: ambiguous)
        }
        let invalid: ReplaySelector<String, SelectionFixtures.Record> = .init(
            rule: DiagnosticLabel("invalid"))
        { _, records in
            .equivalent([records[0].identity, records[0].identity])
        }
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claim(matching: "same", using: invalid)
        }
        let foreignTrackID = TrackID(attachmentID: trackID.attachmentID, key: TrackKey(rawValue: "elsewhere"))
        let foreign: ReplaySelector<String, SelectionFixtures.Record> = .init(
            rule: DiagnosticLabel("foreign"))
        { _, _ in
            .equivalent([RecordIdentity(trackID: foreignTrackID, sequence: 0)])
        }
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claim(matching: "same", using: foreign)
        }
        _ = try lease.claim(matching: "same", using: SelectionFixtures.exact)
        _ = try lease.claim(matching: "same", using: SelectionFixtures.exact)
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claim(matching: "same", using: SelectionFixtures.exact)
        }
        let result = await execution.finish()
        assertSelectionFailures(result, trackID: trackID)
    }

    private func assertSelectionFailures(_ result: ScenarioFinalizationResult, trackID: TrackID) {
        #expect(result.usage[0].tracks[0].activity == .replay(claimedCount: 2, unclaimedCount: 0))
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.selection(.noMatch)),
            .sequential(.selection(.ambiguous([
                RecordIdentity(trackID: trackID, sequence: 0), RecordIdentity(trackID: trackID, sequence: 1),
            ]))),
            .sequential(.selection(.invalidSelectorResult)),
            .sequential(.selection(.invalidSelectorResult)),
            .sequential(.selection(.exhausted([
                RecordIdentity(trackID: trackID, sequence: 0), RecordIdentity(trackID: trackID, sequence: 1),
            ]))),
        ])
        #expect(result.report.diagnostics.map(\.diagnostic.context) == Array(repeating: .track(trackID), count: 5))
        #expect(result.report.diagnostics.first?.diagnostic.fieldPath == [DiagnosticLabel("input")])
        #expect(result.evaluate(.noUnexpectedOperations).failures.count == 5)
        #expect(result.evaluate(.allRecordsClaimed).isSatisfied)
        let rendered = result.rendered()
        #expect(rendered.contains("selection-no-match"))
        #expect(rendered.contains("selection-ambiguous candidates=[0,1]"))
        #expect(rendered.contains("selection-invalid-result"))
        #expect(rendered.contains("selection-exhausted matches=[0,1]"))
        #expect(rendered.contains("fields=[\"input\"] rule=\"exact-input\""))
    }

    @Test
    func `concurrent equivalent claims never reuse one record and selector can inspect lease`() async throws {
        let groups = try (0..<32).map { try SelectionFixtures.group("same", output: String($0)) }
        let (execution, lease) = try SelectionFixtures.start(groups)
        let observed = Mutex(false)
        let selector: ReplaySelector<String, SelectionFixtures.Record> = .init(
            rule: DiagnosticLabel("reentrant"))
        { _, records in
            observed.withLock { $0 = !lease.isClosed }
            return .equivalent(records.map(\.identity))
        }
        let selected = try await withThrowingTaskGroup(of: UInt64.self) { tasks in
            for _ in groups {
                tasks.addTask {
                    let claim = try lease.claim(matching: "same", using: selector)
                    #expect(claim.markConsumed())
                    return claim.record.identity.sequence
                }
            }
            var sequences: [UInt64] = []
            for try await sequence in tasks {
                sequences.append(sequence)
            }
            return sequences
        }
        #expect(selected.sorted() == Array(0..<UInt64(groups.count)))
        #expect(observed.withLock { $0 })
        let result = await execution.finish()
        #expect(result.usage[0].tracks[0].activity == .replay(claimedCount: 32, unclaimedCount: 0))
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
    }

    @Test
    func `sequential record selection advances once and closed use stays diagnosed`() async throws {
        let (execution, lease) = try SelectionFixtures.start([
            SelectionFixtures.group("first", output: "one"),
            SelectionFixtures.group("second", output: "two"),
        ])
        let selector = ReplaySelector<Void, SelectionFixtures.Record>.sequential()
        let first = try lease.claim(matching: (), using: selector)
        #expect(first.record.identity.sequence == 0)
        // Abandoning replay does not return its record to availability.
        #expect(try lease.claim(matching: (), using: selector).record.identity.sequence == 1)
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claim(matching: (), using: selector)
        }
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.selection(.exhausted([
                RecordIdentity(trackID: lease.id, sequence: 0),
                RecordIdentity(trackID: lease.id, sequence: 1),
            ]))),
        ])
        #expect(result.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(result.evaluate(.allClaimedRecordsConsumed).failures.count == 2)
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claim(matching: (), using: selector)
        }
        #expect(await execution.finish().report == result.report)
        #expect(lease.reporter.postFinishDiagnostics.last?.diagnostic.issue == .lifecycle(.leaseClosed))
    }

    @Test
    func `invalid selector identities and wrong mode cannot claim a group`() async throws {
        let group = try SelectionFixtures.group("one", output: "one")
        let (execution, lease) = try SelectionFixtures.start([group])
        let invalid: ReplaySelector<Void, SelectionFixtures.Record> = .init(
            rule: DiagnosticLabel("invalid-index"))
        { _, _ in
            .equivalent([RecordIdentity(trackID: lease.id, sequence: 99)])
        }
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claim(matching: (), using: invalid)
        }
        #expect(try lease.claim(matching: (), using: .sequential()).record.identity.sequence == 0)
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.selection(.invalidSelectorResult)),
        ])

        let (recording, recordLease) = try SelectionFixtures.start([group], mode: .record)
        #expect(throws: SequentialOperationFailure.self) {
            try recordLease.claim(matching: (), using: .sequential())
        }
        #expect(await recording.finish().report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.wrongMode(expected: .replay, actual: .record)),
        ])
    }

    @Test
    func `record unused identities remain ordered when claims have holes and waiver applies`() async throws {
        let (execution, lease) = try SelectionFixtures.start([
            SelectionFixtures.group("first", output: "one"),
            SelectionFixtures.group("second", output: "two"),
            SelectionFixtures.group("third", output: "three"),
        ], allowsUnused: true)
        let trackID = lease.id
        _ = try lease.claim(matching: "second", using: SelectionFixtures.exact)
        let result = await execution.finish()
        #expect(result.usage[0].tracks[0].unclaimedRecords == [
            RecordIdentity(trackID: trackID, sequence: 0),
            RecordIdentity(trackID: trackID, sequence: 2),
        ])
        #expect(result.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(result.evaluate(.allClaimedRecordsConsumed).failures == [
            .unconsumedRecord(RecordIdentity(trackID: trackID, sequence: 1)),
        ])
        #expect(result.evaluate(.allClaimedRecordsConsumed, attachments: []).isSatisfied)
    }
}
