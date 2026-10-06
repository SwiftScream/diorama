/// Continuation for exhausted or closed synchronous replay reads.
///
/// Every failed read still records its diagnostic before returning or throwing.
/// Configured fallback and default values are setup-authored stable values.
/// Returning a continuation creates no record identity or consumption fact.
/// Wrong-mode and explicit-claim failures always throw, regardless of this policy.
public enum ReplayContinuationPolicy<Value: Sendable>: Sendable {
    /// Throw after reporting the failed read. Retain no continuation value.
    case error
    /// Return this value after reporting exhaustion or closure.
    case fallback(Value)
    /// Repeat the most recently consumed stored value.
    /// Use the default until that first consumption, including after closure.
    case replayLast(defaultValue: Value)
}

/// Runtime continuation retains only the value needed for the next failed read.
enum ReplayContinuationState<Value: Sendable>: Sendable {
    case error
    case fallback(Value)
    case replayLast(Value)

    init(_ policy: ReplayContinuationPolicy<Value>) {
        switch policy {
        case .error: self = .error
        case let .fallback(value): self = .fallback(value)
        case let .replayLast(value): self = .replayLast(value)
        }
    }

    mutating func consume(_ value: Value) {
        if case .replayLast = self {
            self = .replayLast(value)
        }
    }

    func resolve(_ failure: SequentialOperationFailure) -> SequentialReadResult<Value> {
        switch self {
        case .error: .failure(failure)
        case let .fallback(value), let .replayLast(value): .continuation(value, failure)
        }
    }
}

/// Select under lease isolation, then report outside it before returning.
enum SequentialReadResult<Value: Sendable> {
    case consumed(Value)
    case continuation(Value, SequentialOperationFailure)
    case failure(SequentialOperationFailure)

    func report(using reporter: DiagnosticReporter) throws(SequentialOperationFailure) -> Value {
        switch self {
        case let .consumed(value):
            return value
        case let .continuation(value, failure):
            reporter.record(failure.diagnostic)
            return value
        case let .failure(failure):
            reporter.record(failure.diagnostic)
            throw failure
        }
    }
}
