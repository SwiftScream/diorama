import DioramaPersistence

/// An optional observed response decision; absence is represented by ordinary body delivery.
///
/// Native adapters create this phase only for a consumer-visible callback. Private
/// forwarding allows and effective completion/async allows never create a phase.
public struct HTTPResponseDispositionPhase<Failure: Sendable>: Sendable {
    /// Delay to presentation from the owning head or the current redirect refusal.
    public let after: HTTPDelay
    /// The sole recorded decision and its continuation.
    public let outcome: HTTPResponseDispositionOutcome<Failure>

    /// Builds a decision boundary without persisting application decision latency.
    public init(after: HTTPDelay, outcome: HTTPResponseDispositionOutcome<Failure>) {
        self.after = after
        self.outcome = outcome
    }

    /// Body exposed after allow; cancellation and unanswered decisions expose none.
    public var body: HTTPBodyDelivery<Failure>? {
        if case let .allow(body) = outcome {
            body
        } else {
            nil
        }
    }

    /// Selects the current answer without callbacks, scheduling, or live fallback.
    /// Returned body/failure delays start when the current answer completes.
    public func continuation(for decision: HTTPResponseDispositionDecision)
        throws(HTTPResponseDispositionError) -> HTTPResponseDispositionContinuation<Failure>
    {
        switch (outcome, decision) {
        case let (.allow(body), .allow): .deliverBody(body)
        case let (.cancel(failure), .cancel): .failed(failure)
        case (.openAtRecordingHorizon, _): throw .decisionBeyondRecordingHorizon
        default: throw .incompatibleDecision
        }
    }
}

/// Exactly one response decision outcome; cancel cannot also own a successful body.
public enum HTTPResponseDispositionOutcome<Failure: Sendable>: Sendable {
    /// Allow body delivery, including its returned, failed, or open conclusion.
    case allow(HTTPBodyDelivery<Failure>)
    /// Cancel and deliver its resulting dependency failure exactly once.
    case cancel(HTTPTimed<Failure>)
    /// No consumer answer occurs before the recording horizon.
    case openAtRecordingHorizon
}

/// A current supported consumer response decision.
public enum HTTPResponseDispositionDecision: Equatable, Sendable {
    /// Continue receiving the body.
    case allow
    /// Cancel response delivery, distinct from caller task cancellation.
    case cancel
}

/// The sole selected continuation after a current response decision.
public enum HTTPResponseDispositionContinuation<Failure: Sendable>: Sendable {
    /// Deliver under the existing response head.
    case deliverBody(HTTPBodyDelivery<Failure>)
    /// Deliver the recorded cancellation failure.
    case failed(HTTPTimed<Failure>)
}

/// Safe infrastructure facts, without native descriptions or dependency failures.
public enum HTTPResponseDispositionError: Error, Equatable, Sendable {
    /// Current allow/cancel differs from the recorded decision.
    case incompatibleDecision
    /// A current answer extends beyond an unanswered recorded horizon.
    case decisionBeyondRecordingHorizon
    /// Download/stream transitions or unknown native dispositions are unsupported.
    case unsupportedTransition
}

extension HTTPResponseDispositionPhase: Equatable where Failure: Equatable {}
extension HTTPResponseDispositionOutcome: Equatable where Failure: Equatable {}
extension HTTPResponseDispositionContinuation: Equatable where Failure: Equatable {}

extension HTTPResponseDispositionPhase: Codable where Failure: Codable {
    private enum Keys: String, CodingKey, CaseIterable { case after, outcome }

    /// Reads exactly one presentation delay and outcome.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: Keys.self)
        try self.init(after: fields.decode(HTTPDelay.self, forKey: .after),
                      outcome: fields.decode(HTTPResponseDispositionOutcome<Failure>.self, forKey: .outcome))
    }

    /// Writes only observed semantics, without decision latency.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: Keys.self)
        try fields.encode(after, forKey: .after)
        try fields.encode(outcome, forKey: .outcome)
    }
}

extension HTTPResponseDispositionOutcome: Codable where Failure: Codable {
    private enum Tag: String, CodingKey, CaseIterable { case kind }
    private enum Allow: String, CodingKey, CaseIterable { case kind, body }
    private enum Cancel: String, CodingKey, CaseIterable { case kind, failure }

    /// Rejects unsupported transitions, duplicate conclusions, and unknown fields.
    public init(from decoder: any Decoder) throws {
        let tag = try decoder.container(keyedBy: Tag.self)
        switch try tag.decode(String.self, forKey: .kind) {
        case "allow":
            let fields = try decoder.strictContainer(keyedBy: Allow.self)
            self = try .allow(fields.decode(HTTPBodyDelivery<Failure>.self, forKey: .body))
        case "cancel":
            let fields = try decoder.strictContainer(keyedBy: Cancel.self)
            self = try .cancel(fields.decode(HTTPTimed<Failure>.self, forKey: .failure))
        case "open":
            _ = try decoder.strictContainer(keyedBy: Tag.self)
            self = .openAtRecordingHorizon
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: tag, debugDescription: "Unsupported HTTP response disposition")
        }
    }

    /// Writes one outcome, without an independent body or terminal conclusion.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .allow(body):
            var fields = encoder.container(keyedBy: Allow.self)
            try fields.encode("allow", forKey: .kind)
            try fields.encode(body, forKey: .body)
        case let .cancel(failure):
            var fields = encoder.container(keyedBy: Cancel.self)
            try fields.encode("cancel", forKey: .kind)
            try fields.encode(failure, forKey: .failure)
        case .openAtRecordingHorizon:
            var fields = encoder.container(keyedBy: Tag.self)
            try fields.encode("open", forKey: .kind)
        }
    }
}
