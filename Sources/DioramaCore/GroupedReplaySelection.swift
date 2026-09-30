/// A stable grouped behavior whose recorded conclusion is known at selection.
///
/// Custom systems provide this fact from their strict semantic recording type.
/// An open horizon is a deliberate nonterminal conclusion, not missing data.
public protocol GroupedReplayRecording: Sendable {
    /// Whether recording ended while this behavior was still active.
    var isOpenAtRecordingHorizon: Bool { get }
}

extension InteractionRecording: GroupedReplayRecording {
    public var isOpenAtRecordingHorizon: Bool {
        if case .openAtRecordingHorizon = conclusion {
            true
        } else {
            false
        }
    }
}

extension SubscriptionRecording: GroupedReplayRecording {
    public var isOpenAtRecordingHorizon: Bool {
        if case .openAtRecordingHorizon = conclusion {
            true
        } else {
            false
        }
    }
}

/// A pure system decision over prepared records in one keyed track.
///
/// Equivalent identities are claimed in recorded order. An ambiguous result
/// means the system cannot choose among distinct behaviors. The core validates
/// every supplied identity before changing availability.
public enum GroupedReplaySelection: Sendable {
    /// All records equivalent to the stable live input, including used ones.
    case equivalent([RecordIdentity])
    /// No recorded input matches.
    case noMatch
    /// Several distinct behaviors remain unresolved by the system policy.
    case ambiguous([RecordIdentity])
}

/// A system-owned, deterministic selector for one prepared track.
///
/// The selector and safe-difference callback run outside the lease lock. They
/// must inspect only stable values, avoid live dependencies and mutation, and
/// return the same result for the same input and records. Difference labels
/// describe fields, never captured field values.
public struct GroupedReplaySelector<Input: Sendable, Value: GroupedReplayRecording>: Sendable {
    /// Safe setup-authored name of the matching policy.
    public let rule: DiagnosticLabel

    let select: @Sendable (Input, [SequentialRecord<Value>]) -> GroupedReplaySelection
    let differences: @Sendable (Input, [SequentialRecord<Value>]) -> [DiagnosticLabel]

    /// Creates a system-specific selector and its safe diagnostic projection.
    public init(
        rule: DiagnosticLabel,
        differences: @escaping @Sendable (Input, [SequentialRecord<Value>]) -> [DiagnosticLabel] = { _, _ in [] },
        select: @escaping @Sendable (Input, [SequentialRecord<Value>]) -> GroupedReplaySelection)
    {
        self.rule = rule
        self.differences = differences
        self.select = select
    }

    /// Matches a stable input by exact equality and claims equivalent records FIFO.
    public static func exactInput(
        _ recordedInput: @escaping @Sendable (Value) -> Input,
        rule: DiagnosticLabel = DiagnosticLabel("exact-input"),
        differences: @escaping @Sendable (Input, [SequentialRecord<Value>]) -> [DiagnosticLabel] = { _, _ in [] })
        -> Self where Input: Equatable
    {
        Self(rule: rule, differences: differences) { input, records in
            let matches = records.filter { recordedInput($0.value) == input }.map(\.identity)
            return matches.isEmpty ? .noMatch : .equivalent(matches)
        }
    }
}

public extension GroupedReplaySelector where Input == Void {
    /// Claims the first available group in track order, without an input matcher.
    static func sequential(rule: DiagnosticLabel = DiagnosticLabel("sequential-group")) -> Self {
        Self(rule: rule) { _, records in
            records.isEmpty ? .noMatch : .equivalent(records.map(\.identity))
        }
    }
}

/// Safe reasons a grouped replay selection could not claim one record.
public enum GroupedReplaySelectionIssue: Equatable, Sendable {
    /// No prepared recording matches the stable input.
    case noMatch
    /// Matching records exist, but every one is already claimed.
    case exhausted([RecordIdentity])
    /// The selector cannot distinguish several non-equivalent candidates.
    case ambiguous([RecordIdentity])
    /// The selector returned an empty, duplicate, foreign, or unknown identity.
    case invalidSelectorResult
}

/// Replay progress remains independent of the group's used state.
public struct GroupedClaimUsage: Equatable, Sendable {
    /// The complete group claimed by one operation.
    public let identity: RecordIdentity
    /// The count of internal lifecycle steps reached by this operation.
    public let progressCount: UInt64
    /// Whether a terminal recorded conclusion was reached, remains pending, or
    /// the recording intentionally ended open at its horizon.
    public let conclusion: Conclusion

    /// The recorded conclusion's replay state.
    public enum Conclusion: Equatable, Sendable {
        /// A terminal conclusion is recorded but has not been reached.
        case pending
        /// The terminal conclusion was reached.
        case completed
        /// The recording explicitly has no terminal conclusion.
        case openAtRecordingHorizon
    }
}

struct GroupedClaimProgress: Sendable {
    var progressCount: UInt64 = 0
    var conclusion: GroupedClaimUsage.Conclusion
}

enum GroupedProgressAction: Sendable {
    case advance(UInt64)
    case complete
}

/// A private, single-use replay lifecycle selected from one grouped track.
///
/// Progress calls are idempotent or monotonic and do not change consumption.
/// A canceled or abandoned claim remains used. An open-at-horizon claim has no
/// terminal conclusion to mark complete.
public struct GroupedReplayClaim<Value: GroupedReplayRecording>: Sendable {
    /// The complete immutable group and its stable identity.
    public let record: SequentialRecord<Value>

    let update: @Sendable (RecordIdentity, GroupedProgressAction) -> Bool

    /// Records how many internal lifecycle steps have been reached.
    /// Returns false after completion or lease closure.
    @discardableResult
    public func advance(to count: UInt64) -> Bool {
        update(record.identity, .advance(count))
    }

    /// Marks the terminal recorded conclusion reached once.
    /// Returns false for an open group or after lease closure.
    @discardableResult
    public func complete() -> Bool {
        update(record.identity, .complete)
    }
}

public extension SequentialTrackLease where Value: GroupedReplayRecording {
    /// Selects and atomically claims a complete grouped recording once.
    ///
    /// The system selector sees all baseline groups so exhaustion differs from
    /// absence. Its callback runs outside the lease lock. Validation, current
    /// availability, and the claim share one lock acquisition. No failure
    /// contacts a live dependency or returns a previously claimed group.
    func claimGrouped<Input: Sendable>(
        matching input: Input,
        using selector: GroupedReplaySelector<Input, Value>)
        throws(SequentialOperationFailure) -> GroupedReplayClaim<Value>
    {
        let snapshot: Result<[SequentialRecord<Value>], SequentialOperationFailure> = state.withLock { state in
            if admissionClosedOrLeaseClosed(state) {
                return .failure(groupedFailure(.leaseClosed, context: .track(id)))
            }
            guard mode == .replay else {
                return .failure(groupedFailure(.wrongMode(expected: .replay, actual: mode), context: .track(id)))
            }
            return .success(state.baseline)
        }
        let records: [SequentialRecord<Value>]
        switch snapshot {
        case let .success(value): records = value
        case let .failure(failure):
            reporter.record(failure.diagnostic)
            throw failure
        }
        let selection = selector.select(input, records)
        let horizons = records.map(\.value.isOpenAtRecordingHorizon)
        let chosen = state.withLock { state in
            claimSelection(selection, horizons: horizons, rule: selector.rule, state: &state)
        }
        switch chosen {
        case let .success(record):
            return GroupedReplayClaim(record: record) { identity, action in
                self.updateGroupedProgress(identity, action: action)
            }
        case let .failure(failure):
            guard case .sequential(.selection) = failure.diagnostic.issue else {
                reporter.record(failure.diagnostic)
                throw failure
            }
            let diagnostic = Diagnostic(issue: failure.diagnostic.issue, context: failure.diagnostic.context,
                                        fieldPath: selector.differences(input, records), rule: selector.rule)
            reporter.record(diagnostic)
            throw SequentialOperationFailure(diagnostic: diagnostic)
        }
    }
}

private extension SequentialTrackLease {
    func claimSelection(
        _ selection: GroupedReplaySelection, horizons: [Bool], rule: DiagnosticLabel,
        state: inout State) -> Result<SequentialRecord<Value>, SequentialOperationFailure>
    {
        if admissionClosedOrLeaseClosed(state) {
            return .failure(groupedFailure(.leaseClosed, context: .track(id)))
        }
        switch selection {
        case .noMatch:
            return .failure(selectionFailure(.noMatch, context: .track(id), rule: rule))
        case let .ambiguous(identities):
            guard let indices = validSelection(identities, records: state.baseline), indices.count > 1 else {
                return .failure(selectionFailure(.invalidSelectorResult, context: .track(id), rule: rule))
            }
            let ordered = indices.sorted().map { state.baseline[$0].identity }
            return .failure(selectionFailure(.ambiguous(ordered), context: .track(id), rule: rule))
        case let .equivalent(identities):
            guard let indices = validSelection(identities, records: state.baseline) else {
                return .failure(selectionFailure(.invalidSelectorResult, context: .track(id), rule: rule))
            }
            let ordered = indices.sorted()
            guard let index = ordered.first(where: { !state.claimed.contains($0) }) else {
                let matches = ordered.map { state.baseline[$0].identity }
                return .failure(selectionFailure(.exhausted(matches), context: .track(id), rule: rule))
            }
            state.claimed.insert(index)
            state.groupedProgress[index] = GroupedClaimProgress(conclusion: horizons[index]
                ? .openAtRecordingHorizon : .pending)
            return .success(state.baseline[index])
        }
    }

    func admissionClosedOrLeaseClosed(_ state: State) -> Bool {
        admission.isClosed || state.closed
    }

    func validSelection(_ identities: [RecordIdentity], records: [SequentialRecord<Value>]) -> [Int]? {
        guard !identities.isEmpty else { return nil }
        var seen: Set<Int> = []
        var indices: [Int] = []
        for identity in identities {
            guard identity.trackID == id, identity.sequence < UInt64(records.count),
                  let index = Int(exactly: identity.sequence), records[index].identity == identity,
                  seen.insert(index).inserted else { return nil }
            indices.append(index)
        }
        return indices
    }

    func updateGroupedProgress(_ identity: RecordIdentity, action: GroupedProgressAction) -> Bool {
        state.withLock { state in
            guard !state.closed, identity.trackID == id, let index = Int(exactly: identity.sequence),
                  var progress = state.groupedProgress[index] else { return false }
            switch action {
            case let .advance(count):
                guard progress.conclusion != .completed else { return false }
                progress.progressCount = max(progress.progressCount, count)
            case .complete:
                guard progress.conclusion != .openAtRecordingHorizon else { return false }
                progress.conclusion = .completed
            }
            state.groupedProgress[index] = progress
            return true
        }
    }

    func groupedFailure(_ issue: ScenarioLifecycleIssue, context: DiagnosticContext) -> SequentialOperationFailure {
        SequentialOperationFailure(diagnostic: Diagnostic(issue: .lifecycle(issue), context: context))
    }

    func groupedFailure(_ issue: SequentialOperationIssue, context: DiagnosticContext) -> SequentialOperationFailure {
        SequentialOperationFailure(diagnostic: Diagnostic(issue: .sequential(issue), context: context))
    }

    func selectionFailure(
        _ issue: GroupedReplaySelectionIssue, context: DiagnosticContext,
        rule: DiagnosticLabel) -> SequentialOperationFailure
    {
        SequentialOperationFailure(diagnostic: Diagnostic(issue: .sequential(.selection(issue)),
                                                          context: context, rule: rule))
    }
}
