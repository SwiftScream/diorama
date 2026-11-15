/// Portable HTTP password-authentication methods; security-object methods are excluded.
public enum HTTPAuthenticationMethod: String, Sendable {
    /// HTTP Basic authentication.
    case basic
    /// HTTP Digest authentication; algorithm execution remains native adapter work.
    case digest
}

/// Portable credential persistence semantics, independent of a native credential store.
public enum HTTPAuthenticationPersistence: String, Sendable {
    /// Do not retain the credential.
    case none
    /// Retain for the current session.
    case forSession
    /// Retain permanently.
    case permanent
    /// Retain through synchronized storage.
    case synchronizable
}

/// Prepared identity and password-presence metadata, never password material.
///
/// Construction is structural only. Adapters must prepare usernames before admission,
/// matching, diagnostics, or persistence, including proposed credentials.
/// Password contents are excluded. Credentials with different passwords can have
/// identical prepared metadata; consumers test password correctness separately.
public struct HTTPAuthenticationCredential: Equatable, Sendable {
    /// Optional prepared username; absence differs from an empty username.
    public let user: String?
    /// Whether the native credential contains a password, without its contents.
    public let hasPassword: Bool
    /// Requested storage behavior, without any store reference.
    public let persistence: HTTPAuthenticationPersistence

    /// Builds metadata from already detached values; no password argument exists.
    public init(user: String?, hasPassword: Bool, persistence: HTTPAuthenticationPersistence) {
        self.user = user
        self.hasPassword = hasPassword
        self.persistence = persistence
    }
}

/// Prepared protection-space metadata attached to the one owning HTTP response.
public struct HTTPAuthenticationChallenge: Equatable, Sendable {
    /// Supported password-authentication method.
    public let method: HTTPAuthenticationMethod
    /// Prepared protection-space host.
    public let host: String
    /// Protection-space port in the inclusive range 0...65535.
    public let port: Int
    /// Optional native protocol spelling, without normalization.
    public let `protocol`: String?
    /// Optional prepared realm; absence differs from an empty realm.
    public let realm: String?
    /// Whether the owning response is a proxy's 407 rather than an origin's 401.
    public let isProxy: Bool
    /// Number of preceding failed authentication attempts.
    public let previousFailureCount: Int
    /// Optional proposed credential's safe metadata; never its password.
    public let proposedCredential: HTTPAuthenticationCredential?

    /// Validates scalar structure; confidentiality policy remains a separate boundary.
    public init(method: HTTPAuthenticationMethod, host: String, port: Int, protocol: String?, realm: String?,
                isProxy: Bool, previousFailureCount: Int, proposedCredential: HTTPAuthenticationCredential?) throws
    {
        guard !host.isEmpty, (0...65535).contains(port), previousFailureCount >= 0 else {
            throw HTTPAuthenticationError.invalidChallenge
        }
        self.method = method
        self.host = host
        self.port = port
        self.protocol = `protocol`
        self.realm = realm
        self.isProxy = isProxy
        self.previousFailureCount = previousFailureCount
        self.proposedCredential = proposedCredential
    }
}

/// One response-owned challenge presentation and its only recorded outcome.
public struct HTTPAuthenticationPhase<Failure: Sendable>: Sendable {
    /// Successive delay from the owning response head to presentation.
    public let after: HTTPDelay
    /// Prepared metadata, without a duplicate failure response or native objects.
    public let challenge: HTTPAuthenticationChallenge
    /// The only observed answer and continuation, or an explicit unanswered horizon.
    public let outcome: HTTPAuthenticationOutcome<Failure>

    /// Composes strict values without persisting application decision latency.
    public init(after: HTTPDelay, challenge: HTTPAuthenticationChallenge, outcome: HTTPAuthenticationOutcome<Failure>) {
        self.after = after
        self.challenge = challenge
        self.outcome = outcome
    }

    /// Selects using the current prepared disposition and exact safe credential shape.
    ///
    /// This performs no scheduling, authentication algorithm, or live access. Returned
    /// delays begin at completion of the current answer. Delivery owners report thrown
    /// infrastructure facts separately from recorded dependency failures.
    /// A different password with identical prepared metadata selects the same retry.
    /// Consumers are responsible for testing that the expected password is supplied.
    public func continuation(for decision: HTTPAuthenticationDecision)
        throws(HTTPAuthenticationSelectionError) -> HTTPAuthenticationContinuation<Failure>
    {
        switch (outcome, decision) {
        case let (.useCredential(expected, retry), .useCredential(actual)):
            guard expected == actual else { throw .incompatibleDecision }
            return .retry(retry)
        case let (.performDefaultHandling(next), .performDefaultHandling),
             let (.rejectProtectionSpace(next), .rejectProtectionSpace):
            return next
        case let (.cancel(failure), .cancel):
            return .failed(failure)
        case (.openAtRecordingHorizon, _):
            throw .decisionBeyondRecordingHorizon
        default:
            throw .incompatibleDecision
        }
    }
}

/// A retry derives its request unless an adapter observes a material prepared change.
public struct HTTPAuthenticationRetry<Failure: Sendable>: Sendable {
    /// An explicit request only when it cannot be faithfully inherited.
    public let request: HTTPRequestMessage?
    /// The next attempt, delayed from completion of the current decision.
    public let result: HTTPAttemptResult<Failure>

    /// Omitting the request inherits the current request without generated auth secrets.
    public init(request: HTTPRequestMessage? = nil, result: HTTPAttemptResult<Failure>) {
        self.request = request
        self.result = result
    }

    /// Resolves the edge using the caller's current effective prepared request.
    public func effectiveRequest(inheriting current: HTTPRequestMessage) -> HTTPRequestMessage {
        request ?? current
    }
}

/// Native-observed progress after default/reject, with no repeated response head.
public enum HTTPAuthenticationContinuation<Failure: Sendable>: Sendable {
    /// Retry with an inherited or explicitly changed effective request.
    case retry(HTTPAuthenticationRetry<Failure>)
    /// Expose content under the owning challenged response, including a failed/open prefix.
    case deliverBody(HTTPBodyDelivery<Failure>)
    /// Fail after answering, without introducing another response.
    case failed(HTTPTimed<Failure>)
    /// The decision was answered but no further event was observed.
    case openAtRecordingHorizon

    var body: HTTPBodyDelivery<Failure>? {
        if case let .deliverBody(body) = self {
            body
        } else {
            nil
        }
    }
}

/// Mutually exclusive authentication decisions and their permitted continuations.
public enum HTTPAuthenticationOutcome<Failure: Sendable>: Sendable {
    /// Use safe identity metadata and retry; password verification is never performed.
    case useCredential(HTTPAuthenticationCredential, HTTPAuthenticationRetry<Failure>)
    /// Preserve the native continuation selected by default handling.
    case performDefaultHandling(HTTPAuthenticationContinuation<Failure>)
    /// Preserve the native continuation selected by rejecting this protection space.
    case rejectProtectionSpace(HTTPAuthenticationContinuation<Failure>)
    /// Cancel the challenge and deliver exactly one resulting dependency failure.
    case cancel(HTTPTimed<Failure>)
    /// No answer was observed; there is no synthetic body, failure, or retry.
    case openAtRecordingHorizon

    var body: HTTPBodyDelivery<Failure>? {
        switch self {
        case let .performDefaultHandling(next), let .rejectProtectionSpace(next): next.body
        case .useCredential, .cancel, .openAtRecordingHorizon: nil
        }
    }
}

/// Current application decision after adapter conversion and identity preparation.
public enum HTTPAuthenticationDecision: Equatable, Sendable {
    /// Use a credential with this prepared identity, presence, and persistence shape.
    case useCredential(HTTPAuthenticationCredential)
    /// Perform native default handling.
    case performDefaultHandling
    /// Reject the protection space.
    case rejectProtectionSpace
    /// Cancel the authentication challenge, distinct from caller task cancellation.
    case cancel
}

/// Safe structural errors without protection-space or credential contents.
public enum HTTPAuthenticationError: Error, Equatable, Sendable {
    /// A host, port, or failure count cannot represent a supported challenge.
    case invalidChallenge
    /// A challenge requires its matching origin 401 or proxy 407 response.
    case invalidResponse
}

/// Safe selection facts, distinct from recorded native dependency failures.
public enum HTTPAuthenticationSelectionError: Error, Equatable, Sendable {
    /// Disposition or prepared credential shape differs from the recorded answer.
    case incompatibleDecision
    /// The recording has no continuation for an answer beyond its horizon.
    case decisionBeyondRecordingHorizon
}

extension HTTPAuthenticationPhase: Equatable where Failure: Equatable {}
extension HTTPAuthenticationOutcome: Equatable where Failure: Equatable {}
extension HTTPAuthenticationRetry: Equatable where Failure: Equatable {}
extension HTTPAuthenticationContinuation: Equatable where Failure: Equatable {}
