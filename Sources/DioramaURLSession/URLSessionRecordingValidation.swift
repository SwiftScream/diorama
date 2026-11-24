import DioramaCore
import DioramaHTTP
import Foundation

/// Observable behavior a native bridge has proved for replay.
/// Storage placement and authored timing use the same native behavior as inline, observed values.
public enum URLSessionReplayCapability: Hashable, Sendable {
    /// Data task handling for the given HTTP method.
    case requestMethod(String)
    /// In-memory request content, including a present empty body.
    case requestBody
    /// Delivery of response bytes, including an empty delivery.
    case responseBody
    /// Delivery at the recorded segment boundaries.
    case segmentedBody
    /// Native presentation of a dependency failure.
    case failure
    /// Keeping an operation pending through its recording horizon.
    case openHorizon
    /// Handling a redirect proposal with this status and its recorded decision.
    case redirect(status: Int)
    /// Handling the indicated origin or proxy challenge and its recorded decision.
    case authentication(HTTPAuthenticationMethod, isProxy: Bool)
    /// Waiting for the consumer's response decision.
    case responseDecision
    /// Effective cancellation by the consumer's response decision.
    case dispositionCancellation
    /// Presentation of trailers after body delivery.
    case trailers

    fileprivate var requirementRule: DiagnosticLabel {
        let label: StaticString = switch self {
        case .requestMethod: "urlsession.requires-request-method"
        case .requestBody: "urlsession.requires-request-body"
        case .responseBody: "urlsession.requires-response-body"
        case .segmentedBody: "urlsession.requires-segmented-body"
        case .failure: "urlsession.requires-failure"
        case .openHorizon: "urlsession.requires-open-horizon"
        case .redirect: "urlsession.requires-redirect"
        case .authentication: "urlsession.requires-authentication"
        case .responseDecision: "urlsession.requires-response-decision"
        case .dispositionCancellation: "urlsession.requires-disposition-cancellation"
        case .trailers: "urlsession.requires-trailers"
        }
        return DiagnosticLabel(label)
    }
}

/// A safe location within the attachment's ordered interactions and successive attempts.
public struct URLSessionRecordingLocation: Equatable, Sendable {
    /// Attachment, track, and zero-based interaction position.
    public let record: RecordIdentity
    /// Zero-based attempt within the recorded redirect and challenge chain.
    public let attempt: Int
    /// Schema field within this attempt. Contains only system-owned labels.
    public let fieldPath: [DiagnosticLabel]
}

/// Whole-record admission failures, distinct from recorded URLSession failures.
public enum URLSessionRecordingError: Error, Equatable, Sendable {
    /// An authored value violates URLSession scope or its selected preparation policy.
    case invalidValue(URLSessionRecordingLocation)
    /// A required behavior is absent from the bridge's supplied conformance profile.
    /// The capability label identifies the failed requirement using fixed schema text.
    case unsupported(URLSessionRecordingLocation, capability: DiagnosticLabel)
}

struct URLSessionRecordingValidation {
    let record: RecordIdentity
    let preparation: HTTPPreparation
    let supports: (@Sendable (URLSessionReplayCapability) -> Bool)?
    private var attempt = 0

    init(_ record: RecordIdentity, preparation: HTTPPreparation,
         supports: (@Sendable (URLSessionReplayCapability) -> Bool)? = nil)
    {
        self.record = record
        self.preparation = preparation
        self.supports = supports
    }

    mutating func inspect(_ interaction: HTTPInteraction<URLSessionFailure>) throws {
        try request(interaction.initialRequest, at: "initialRequest")
        var next: HTTPAttemptResult<URLSessionFailure>? = interaction.result
        while let result = next {
            next = try inspect(result)
            attempt += 1
        }
    }

    private func inspect(_ result: HTTPAttemptResult<URLSessionFailure>) throws
        -> HTTPAttemptResult<URLSessionFailure>?
    {
        switch result {
        case .failed: try require(.failure, at: "result.failure")
        case .openAtRecordingHorizon: try require(.openHorizon, at: "result")
        case let .received(response):
            let head = response.head.value.head
            try validate(at: "response.head.fields") {
                try preparation.fieldRedaction.validatePrepared(head.headerFields)
            }
            switch response.next {
            case let .deliverBody(value): try body(value)
            case let .authenticate(phase): return try authentication(phase)
            case let .redirect(phase):
                try require(.redirect(status: head.status.code), at: "response.next.redirect")
                return try redirect(phase)
            case let .disposition(phase): try disposition(phase)
            }
        }
        return nil
    }

    private func redirect(_ phase: HTTPRedirectPhase<URLSessionFailure>) throws
        -> HTTPAttemptResult<URLSessionFailure>?
    {
        try request(phase.proposedRequest, at: "redirect.proposedRequest")
        switch phase.outcome {
        case let .followProposed(result): return result
        case let .followModified(modified, result):
            try request(modified, at: "redirect.outcome.request")
            return result
        case let .refuse(.deliverBody(value)): try body(value)
        case let .refuse(.disposition(value)): try disposition(value)
        case .openAtRecordingHorizon: try require(.openHorizon, at: "redirect.outcome")
        }
        return nil
    }

    private func authentication(_ phase: HTTPAuthenticationPhase<URLSessionFailure>) throws
        -> HTTPAttemptResult<URLSessionFailure>?
    {
        let challenge = phase.challenge
        try require(.authentication(challenge.method, isProxy: challenge.isProxy), at: "authenticate.challenge")
        try validate(at: "authenticate.challenge.proposedCredential.user") {
            _ = try preparation.authenticationChallenge().admitPrepared(challenge)
        }
        switch phase.outcome {
        case let .useCredential(credential, retry):
            try validate(at: "authenticate.outcome.credential.user") {
                _ = try preparation.authenticationCredential().admitPrepared(credential)
            }
            return try nextAttempt(retry)
        case let .performDefaultHandling(next), let .rejectProtectionSpace(next):
            switch next {
            case let .retry(retry): return try nextAttempt(retry)
            case let .deliverBody(value): try body(value)
            case .failed: try require(.failure, at: "authenticate.outcome.continuation.failure")
            case .openAtRecordingHorizon: try require(.openHorizon, at: "authenticate.outcome.continuation")
            }
        case .cancel: try require(.failure, at: "authenticate.outcome.failure")
        case .openAtRecordingHorizon: try require(.openHorizon, at: "authenticate.outcome")
        }
        return nil
    }

    private func nextAttempt(_ retry: HTTPAuthenticationRetry<URLSessionFailure>) throws
        -> HTTPAttemptResult<URLSessionFailure>
    {
        if let changed = retry.request {
            try request(changed, at: "authenticate.retry.request")
        }
        return retry.result
    }

    private func disposition(_ phase: HTTPResponseDispositionPhase<URLSessionFailure>) throws {
        try require(.responseDecision, at: "disposition.outcome")
        switch phase.outcome {
        case let .allow(value): try body(value)
        case .cancel:
            try require(.dispositionCancellation, at: "disposition.outcome")
            try require(.failure, at: "disposition.outcome.failure")
        case .openAtRecordingHorizon: try require(.openHorizon, at: "disposition.outcome")
        }
    }

    private func body(_ value: HTTPBodyDelivery<URLSessionFailure>) throws {
        switch value.content {
        case .bytes, .resource: try require(.responseBody, at: "body.content")
        case .absent, .unavailable: break
        }
        if value.profile != nil {
            try require(.segmentedBody, at: "body.segments")
        }
        switch value.conclusion {
        case .failed: try require(.failure, at: "body.conclusion.failure")
        case .openAtRecordingHorizon: try require(.openHorizon, at: "body.conclusion")
        case let .returned(completion):
            if let trailers = completion.trailers {
                try validate(at: "body.conclusion.completion.trailers.fields") {
                    try preparation.fieldRedaction.validatePrepared(trailers.fields)
                }
                try require(.trailers, at: "body.conclusion.completion.trailers")
            }
        }
    }

    private func request(_ message: HTTPRequestMessage, at field: StaticString) throws {
        let head = message.head
        switch head.scheme?.lowercased() {
        case "http", "https": break
        default: throw URLSessionRecordingError.invalidValue(location(field, "scheme"))
        }
        guard let authority = head.authority, !authority.isEmpty else {
            throw URLSessionRecordingError.invalidValue(location(field, "authority"))
        }
        guard head.path != nil else {
            throw URLSessionRecordingError.invalidValue(location(field, "path"))
        }
        guard let url = head.url, let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw URLSessionRecordingError.invalidValue(location(field))
        }
        try validate(at: field, "fields") { try preparation.fieldRedaction.validatePrepared(head.headerFields) }
        try require(.requestMethod(head.method.rawValue), at: field, "method")
        if message.body != .absent {
            try require(.requestBody, at: field, "body")
        }
    }

    private func validate(at field: StaticString, _ suffix: StaticString? = nil, _ check: () throws -> Void) throws {
        do { try check() } catch {
            throw URLSessionRecordingError.invalidValue(location(field, suffix))
        }
    }

    private func require(_ capability: URLSessionReplayCapability, at field: StaticString,
                         _ suffix: StaticString? = nil) throws
    {
        if let supports, !supports(capability) {
            throw URLSessionRecordingError.unsupported(location(field, suffix), capability: capability.requirementRule)
        }
    }

    private func location(_ field: StaticString, _ suffix: StaticString? = nil) -> URLSessionRecordingLocation {
        var path = [DiagnosticLabel(field)]
        if let suffix {
            path.append(DiagnosticLabel(suffix))
        }
        return URLSessionRecordingLocation(record: record, attempt: attempt, fieldPath: path)
    }
}
