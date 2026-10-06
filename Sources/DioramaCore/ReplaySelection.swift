/// A pure system decision over prepared records in one keyed track.
///
/// Equivalent identities are claimed in recorded order. An ambiguous result
/// means the system cannot choose among distinct behaviors. The core validates
/// every supplied identity before changing availability.
public enum ReplaySelection: Sendable {
    /// All records equivalent to the stable live input, including claimed ones.
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
public struct ReplaySelector<Input: Sendable, Value: Sendable>: Sendable {
    /// Safe setup-authored name of the matching policy.
    public let rule: DiagnosticLabel

    let select: @Sendable (Input, [SequentialRecord<Value>]) -> ReplaySelection
    let differences: @Sendable (Input, [SequentialRecord<Value>]) -> [DiagnosticLabel]

    /// Creates a system-specific selector and its safe diagnostic projection.
    public init(
        rule: DiagnosticLabel,
        differences: @escaping @Sendable (Input, [SequentialRecord<Value>]) -> [DiagnosticLabel] = { _, _ in [] },
        select: @escaping @Sendable (Input, [SequentialRecord<Value>]) -> ReplaySelection)
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

public extension ReplaySelector where Input == Void {
    /// Claims the first available record in track order, without an input matcher.
    static func sequential(rule: DiagnosticLabel = DiagnosticLabel("sequential-record")) -> Self {
        Self(rule: rule) { _, records in
            records.isEmpty ? .noMatch : .equivalent(records.map(\.identity))
        }
    }
}

/// Safe reasons a record replay selection could not claim one record.
public enum ReplaySelectionIssue: Equatable, Sendable {
    /// No prepared recording matches the stable input.
    case noMatch
    /// Matching records exist, but every one is already claimed.
    case exhausted([RecordIdentity])
    /// The selector cannot distinguish several non-equivalent candidates.
    case ambiguous([RecordIdentity])
    /// The selector returned an empty, duplicate, foreign, or unknown identity.
    case invalidSelectorResult
}

/// System-reported replay progress for a record that has already been claimed.
public struct ReplayClaimUsage: Equatable, Sendable {
    /// The record exclusively assigned to one operation.
    public let identity: RecordIdentity
    /// The system-reported count of replay steps reached by this operation.
    public let progressCount: UInt64
    /// Whether the system has acknowledged replaying all recorded behavior.
    /// This does not imply that the simulated operation has terminated.
    public let isConsumed: Bool
}

struct ReplayClaimProgress: Sendable {
    var progressCount: UInt64 = 0
    var isConsumed: Bool = false
}

enum ReplayProgressAction: Sendable {
    case advance(UInt64)
    case markConsumed
}

/// An exclusive claim on one record whose replay is managed by the system.
///
/// A claim starts unconsumed. The system acknowledges consumption after replaying
/// all recorded behavior, including reaching an open recording horizon. Canceling
/// or abandoning replay never returns the record to the available pool.
public struct ReplayClaim<Value: Sendable>: Sendable {
    /// The complete immutable record and its stable identity.
    public let record: SequentialRecord<Value>

    let update: @Sendable (RecordIdentity, ReplayProgressAction) -> Bool

    /// Records how many replay steps the system has reached, monotonically.
    /// Returns false after consumption or lease closure.
    @discardableResult
    public func advance(to count: UInt64) -> Bool {
        update(record.identity, .advance(count))
    }

    /// Acknowledges that the system has replayed all behavior in this record.
    /// Does not perform replay or terminate the simulated operation. Repeated
    /// acknowledgements succeed until lease closure, after which this returns false.
    @discardableResult
    public func markConsumed() -> Bool {
        update(record.identity, .markConsumed)
    }
}
