import HTTPTypes

/// A response-owned proposal and exactly one observed decision/continuation.
public struct HTTPRedirectPhase<Failure: Sendable>: Sendable {
    /// Successive delay from the owning response head to presentation.
    public let after: HTTPDelay
    /// The complete prepared native proposal, stored once without deriving URL policy.
    public let proposedRequest: HTTPRequestMessage
    /// The only recorded branch; unanswered decisions remain explicitly open.
    public let outcome: HTTPRedirectOutcome<Failure>

    /// Composes validated values; decision latency is deliberately absent.
    public init(after: HTTPDelay, proposedRequest: HTTPRequestMessage, outcome: HTTPRedirectOutcome<Failure>) {
        self.after = after
        self.proposedRequest = proposedRequest
        self.outcome = outcome
    }

    /// The next effective request, derived from its edge rather than a second root.
    public var effectiveRequest: HTTPRequestMessage? {
        switch outcome {
        case .followProposed: proposedRequest
        case let .followModified(request, _): request
        case .refuse, .openAtRecordingHorizon: nil
        }
    }

    /// Selects the single continuation using the current prepared application decision.
    ///
    /// Supply the setup's pure request equivalence rule over prepared values, such
    /// as HTTPRequestMatcher projections. A mismatch throws a safe infrastructure
    /// fact; this operation performs no delivery or live access. The returned
    /// delays start at completion of the current decision, excluding caller latency.
    public func continuation(
        for decision: HTTPRedirectDecision,
        requestsMatch: (HTTPRequestMessage, HTTPRequestMessage) -> Bool)
        throws(HTTPRedirectSelectionError) -> HTTPRedirectContinuation<Failure>
    {
        switch (outcome, decision) {
        case let (.followProposed(result), .follow(request)):
            guard requestsMatch(proposedRequest, request) else { throw .incompatibleDecision }
            return .attempt(request: proposedRequest, result: result)
        case let (.followModified(expected, result), .follow(request)):
            guard requestsMatch(expected, request) else { throw .incompatibleDecision }
            return .attempt(request: expected, result: result)
        case let (.refuse(body), .refuse):
            return .deliverBody(body)
        case (.openAtRecordingHorizon, _):
            throw .decisionBeyondRecordingHorizon
        default:
            throw .incompatibleDecision
        }
    }
}

/// One recorded decision branch, with no duplicate response or derivable request.
public enum HTTPRedirectOutcome<Failure: Sendable>: Sendable {
    /// The proposal is the effective request; the attempt starts at decision completion.
    case followProposed(HTTPAttemptResult<Failure>)
    /// A material modification owns its complete effective request once.
    case followModified(HTTPRequestMessage, HTTPAttemptResult<Failure>)
    /// The owning redirect response delivers its content, prefix, and conclusion.
    case refuse(HTTPBodyDelivery<Failure>)
    /// No decision is observed before the horizon; there is no body or next attempt.
    case openAtRecordingHorizon
}

/// A current application choice after native conversion and setup preparation.
public enum HTTPRedirectDecision: Equatable, Sendable {
    /// Follow this effective prepared request, whether modified or unchanged.
    case follow(HTTPRequestMessage)
    /// Expose the redirect response rather than starting another request.
    case refuse
}

/// A compatible continuation whose local timing starts at the current decision.
public enum HTTPRedirectContinuation<Failure: Sendable>: Sendable {
    /// Start the next attempt using the edge's derived effective request.
    case attempt(request: HTTPRequestMessage, result: HTTPAttemptResult<Failure>)
    /// Deliver content under the existing response head, without duplicating it.
    case deliverBody(HTTPBodyDelivery<Failure>)
}

/// Safe branch-selection facts, distinct from any recorded adapter failure.
public enum HTTPRedirectSelectionError: Error, Equatable, Sendable {
    /// The current choice or effective request cannot select the recorded branch.
    case incompatibleDecision
    /// The recording contains no continuation for an answered decision.
    case decisionBeyondRecordingHorizon
}

extension HTTPRedirectPhase: Equatable where Failure: Equatable {}
extension HTTPRedirectOutcome: Equatable where Failure: Equatable {}
extension HTTPRedirectContinuation: Equatable where Failure: Equatable {}

extension HTTPAttemptResult {
    private enum RequestContextKey: String, CodingKey {
        case response, head, value, fields, next, redirect, outcome, result
    }

    func validateRequestMethod(_ method: HTTPRequest.Method, codingPath: [any CodingKey]? = nil) throws {
        guard case let .received(response) = self else { return }
        if response.head.value.derivesContentLength {
            guard HTTPContentLength.unambiguous(method: method) else {
                if let codingPath {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: codingPath + [
                            RequestContextKey.response, RequestContextKey.head,
                            RequestContextKey.value, RequestContextKey.fields,
                        ],
                        debugDescription: "Derived HTTP response length conflicts with its effective request method"))
                }
                throw HTTPMessageError.invalidField
            }
        }
        guard case let .redirect(phase) = response.next else { return }
        let nextPath = codingPath.map {
            $0 + [
                RequestContextKey.response, RequestContextKey.next, RequestContextKey.redirect,
                RequestContextKey.outcome, RequestContextKey.result,
            ]
        }
        switch phase.outcome {
        case let .followProposed(result):
            try result.validateRequestMethod(phase.proposedRequest.head.method, codingPath: nextPath)
        case let .followModified(request, result):
            try result.validateRequestMethod(request.head.method, codingPath: nextPath)
        case .refuse, .openAtRecordingHorizon:
            break
        }
    }
}
