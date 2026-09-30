@testable import DioramaCore
import Synchronization
import Testing

private enum SelectionFixtures {
    typealias Group = InteractionRecording<String, String, String, String, String>

    static let type = ScenarioSystemType("selection")

    static func group(_ input: String, output: String? = nil) throws -> Group {
        let conclusion: InteractionConclusion<String, String> = if let output {
            try .returned(LifecycleMoment(offset: .zero, value: output))
        } else {
            .openAtRecordingHorizon
        }
        return try Group(input: input, phases: [], conclusion: conclusion)
    }

    static func start(_ groups: [Group], key: String = "one", allowsUnused: Bool = false,
                      mode: ScenarioMode = .replay)
        throws -> (ScenarioExecution, HeaderlessSequentialTrackLease<Group>)
    {
        let attachmentID = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: key))
        let trackID = TrackID(attachmentID: attachmentID, key: TrackKey(rawValue: "groups"))
        let policy = ValuePreparation<Group>()
        let values = try groups.map { try policy.admitPrepared($0) }
        let attachment = try ScenarioAttachment(id: attachmentID)
            .adding(SequentialTrack(id: trackID, values: values))
        let system = try ScenarioSystem(type: type, attachment: attachment,
                                        allowsUnusedReplayRecords: allowsUnused)
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

    static var exact: GroupedReplaySelector<String, Group> {
        .exactInput(\.input, differences: { _, _ in [DiagnosticLabel("input")] })
    }
}

@Suite(.timeLimit(.minutes(1)))
struct GroupedReplaySelectionTests {
    @Test
    func `reordered distinct calls and repeated equivalents claim whole groups in recorded order`() async throws {
        let groups = try [
            SelectionFixtures.group("repeat", output: "first"),
            SelectionFixtures.group("distinct", output: "other"),
            SelectionFixtures.group("repeat", output: "second"),
            SelectionFixtures.group("open"),
        ]
        let (execution, lease) = try SelectionFixtures.start(groups)
        let trackID = lease.id
        let distinct = try lease.claimGrouped(matching: "distinct", using: SelectionFixtures.exact)
        let first = try lease.claimGrouped(matching: "repeat", using: SelectionFixtures.exact)
        let second = try lease.claimGrouped(matching: "repeat", using: SelectionFixtures.exact)
        let open = try lease.claimGrouped(matching: "open", using: SelectionFixtures.exact)
        #expect(distinct.record.identity.sequence == 1)
        #expect(first.record.identity.sequence == 0)
        #expect(second.record.identity.sequence == 2)
        #expect(open.record.identity.sequence == 3)
        #expect(try first.record.value.conclusion == .returned(LifecycleMoment(offset: .zero, value: "first")))
        #expect(try second.record.value.conclusion == .returned(LifecycleMoment(offset: .zero, value: "second")))
        #expect(distinct.advance(to: 2))
        #expect(distinct.complete())
        #expect(first.advance(to: 1))
        #expect(first.advance(to: 1))
        #expect(second.complete())
        #expect(!open.complete())
        let result = await execution.finish()
        let usage = result.usage[0].tracks[0]
        #expect(usage.activity == .replay(usedCount: 4, unusedCount: 0))
        #expect(usage.unusedRecords.isEmpty)
        #expect(usage.selectedGroups.map(\.identity.sequence) == [0, 1, 2, 3])
        #expect(usage.selectedGroups.map(\.progressCount) == [1, 2, 0, 0])
        #expect(usage.selectedGroups.map(\.conclusion) == [
            .pending, .completed, .completed, .openAtRecordingHorizon,
        ])
        #expect(result.evaluate(.allRecordingsUsed).isSatisfied)
        #expect(result.evaluate(.allSelectedRecordingsCompleted).failures == [
            .incompleteClaim(RecordIdentity(trackID: trackID, sequence: 0)),
        ])
        let rendered = result.rendered()
        #expect(rendered.contains("Claimed record 0 progress=1 pending"))
        #expect(rendered.contains("Claimed record 1 progress=2 completed"))
        #expect(rendered.contains("Claimed record 3 progress=0 open-at-recording-horizon"))
        #expect(!first.advance(to: 3))
        #expect(!first.complete())
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
            try lease.claimGrouped(matching: "absent", using: SelectionFixtures.exact)
        }
        let ambiguous: GroupedReplaySelector<String, SelectionFixtures.Group> = .init(
            rule: DiagnosticLabel("ambiguous"))
        { _, records in
            .ambiguous(records.map(\.identity))
        }
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claimGrouped(matching: "same", using: ambiguous)
        }
        let invalid: GroupedReplaySelector<String, SelectionFixtures.Group> = .init(
            rule: DiagnosticLabel("invalid"))
        { _, records in
            .equivalent([records[0].identity, records[0].identity])
        }
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claimGrouped(matching: "same", using: invalid)
        }
        let foreignTrackID = TrackID(attachmentID: trackID.attachmentID, key: TrackKey(rawValue: "elsewhere"))
        let foreign: GroupedReplaySelector<String, SelectionFixtures.Group> = .init(
            rule: DiagnosticLabel("foreign"))
        { _, _ in
            .equivalent([RecordIdentity(trackID: foreignTrackID, sequence: 0)])
        }
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claimGrouped(matching: "same", using: foreign)
        }
        _ = try lease.claimGrouped(matching: "same", using: SelectionFixtures.exact)
        _ = try lease.claimGrouped(matching: "same", using: SelectionFixtures.exact)
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claimGrouped(matching: "same", using: SelectionFixtures.exact)
        }
        let result = await execution.finish()
        assertSelectionFailures(result, trackID: trackID)
    }

    private func assertSelectionFailures(_ result: ScenarioFinalizationResult, trackID: TrackID) {
        #expect(result.usage[0].tracks[0].activity == .replay(usedCount: 2, unusedCount: 0))
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
        #expect(result.evaluate(.allRecordingsUsed).isSatisfied)
        let rendered = result.rendered()
        #expect(rendered.contains("selection-no-match"))
        #expect(rendered.contains("selection-ambiguous candidates=[0,1]"))
        #expect(rendered.contains("selection-invalid-result"))
        #expect(rendered.contains("selection-exhausted matches=[0,1]"))
        #expect(rendered.contains("fields=[\"input\"] rule=\"exact-input\""))
    }

    @Test
    func `concurrent equivalent claims never reuse one group and selector can inspect lease`() async throws {
        let groups = try (0..<32).map { try SelectionFixtures.group("same", output: String($0)) }
        let (execution, lease) = try SelectionFixtures.start(groups)
        let observed = Mutex(false)
        let selector: GroupedReplaySelector<String, SelectionFixtures.Group> = .init(
            rule: DiagnosticLabel("reentrant"))
        { _, records in
            observed.withLock { $0 = !lease.isClosed }
            return .equivalent(records.map(\.identity))
        }
        let selected = try await withThrowingTaskGroup(of: UInt64.self) { tasks in
            for _ in groups {
                tasks.addTask { try lease.claimGrouped(matching: "same", using: selector).record.identity.sequence }
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
        #expect(result.usage[0].tracks[0].activity == .replay(usedCount: 32, unusedCount: 0))
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.evaluate(.allSelectedRecordingsCompleted).failures.count == 32)
    }

    @Test
    func `sequential grouped selection advances once and closed use stays diagnosed`() async throws {
        let (execution, lease) = try SelectionFixtures.start([
            SelectionFixtures.group("first", output: "one"),
            SelectionFixtures.group("second", output: "two"),
        ])
        let selector = GroupedReplaySelector<Void, SelectionFixtures.Group>.sequential()
        let first = try lease.claimGrouped(matching: (), using: selector)
        #expect(first.record.identity.sequence == 0)
        // Abandoning the private lifecycle does not return its group to availability.
        #expect(try lease.claimGrouped(matching: (), using: selector).record.identity.sequence == 1)
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claimGrouped(matching: (), using: selector)
        }
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.selection(.exhausted([
                RecordIdentity(trackID: lease.id, sequence: 0),
                RecordIdentity(trackID: lease.id, sequence: 1),
            ]))),
        ])
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claimGrouped(matching: (), using: selector)
        }
        #expect(await execution.finish().report == result.report)
        #expect(lease.reporter.postFinishDiagnostics.last?.diagnostic.issue == .lifecycle(.leaseClosed))
    }

    @Test
    func `invalid selector identities and wrong mode cannot claim a group`() async throws {
        let group = try SelectionFixtures.group("one", output: "one")
        let (execution, lease) = try SelectionFixtures.start([group])
        let invalid: GroupedReplaySelector<Void, SelectionFixtures.Group> = .init(
            rule: DiagnosticLabel("invalid-index"))
        { _, _ in
            .equivalent([RecordIdentity(trackID: lease.id, sequence: 99)])
        }
        #expect(throws: SequentialOperationFailure.self) {
            try lease.claimGrouped(matching: (), using: invalid)
        }
        #expect(try lease.claimGrouped(matching: (), using: .sequential()).record.identity.sequence == 0)
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.selection(.invalidSelectorResult)),
        ])

        let (recording, recordLease) = try SelectionFixtures.start([group], mode: .record)
        #expect(throws: SequentialOperationFailure.self) {
            try recordLease.claimGrouped(matching: (), using: .sequential())
        }
        #expect(await recording.finish().report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.wrongMode(expected: .replay, actual: .record)),
        ])
    }

    @Test
    func `strict interaction and subscription conclusions identify intentional open horizons`() throws {
        let interaction = try SelectionFixtures.group("open")
        let terminal = try SelectionFixtures.group("terminal", output: "done")
        let subscription = try SubscriptionRecording<String, String, String>(
            input: "stream", events: [], conclusion: .openAtRecordingHorizon)
        let ended = try SubscriptionRecording<String, String, String>(
            input: "stream", events: [], conclusion: .finished(atTime: nil))
        #expect(interaction.isOpenAtRecordingHorizon)
        #expect(!terminal.isOpenAtRecordingHorizon)
        #expect(subscription.isOpenAtRecordingHorizon)
        #expect(!ended.isOpenAtRecordingHorizon)
    }

    @Test
    func `grouped unused identities remain ordered when claims have holes and waiver applies`() async throws {
        let (execution, lease) = try SelectionFixtures.start([
            SelectionFixtures.group("first", output: "one"),
            SelectionFixtures.group("second", output: "two"),
            SelectionFixtures.group("third", output: "three"),
        ], allowsUnused: true)
        let trackID = lease.id
        _ = try lease.claimGrouped(matching: "second", using: SelectionFixtures.exact)
        let result = await execution.finish()
        #expect(result.usage[0].tracks[0].unusedRecords == [
            RecordIdentity(trackID: trackID, sequence: 0),
            RecordIdentity(trackID: trackID, sequence: 2),
        ])
        #expect(result.evaluate(.allRecordingsUsed).isSatisfied)
        #expect(result.evaluate(.allSelectedRecordingsCompleted).failures == [
            .incompleteClaim(RecordIdentity(trackID: trackID, sequence: 1)),
        ])
        #expect(result.evaluate(.allSelectedRecordingsCompleted, attachments: []).isSatisfied)
    }
}
