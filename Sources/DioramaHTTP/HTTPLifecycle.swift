import HTTPTypes

/// One grouped operation, selected by its initial prepared request.
public struct HTTPInteraction<Failure: Sendable>: Sendable {
    /// The complete authoritative request, stored once at the root.
    public let initialRequest: HTTPRequestMessage
    /// The only attempt result; the leaf determines whether work ends or stays open.
    public let result: HTTPAttemptResult<Failure>

    /// Builds an interaction from structurally valid components.
    ///
    /// System admission separately validates preparation policy and capabilities.
    public init(initialRequest: HTTPRequestMessage, result: HTTPAttemptResult<Failure>) {
        self.initialRequest = initialRequest
        self.result = result
    }
}

/// Mutually exclusive progress before a response head is received.
public enum HTTPAttemptResult<Failure: Sendable>: Sendable {
    /// A response owns all subsequent body progress and its conclusion.
    case received(HTTPResponseNode<Failure>)
    /// A typed adapter failure before any response head.
    case failed(HTTPTimed<Failure>)
    /// Observation ends before a response or failure; replay remains pending.
    case openAtRecordingHorizon
}

/// A single received response with its own head and body lifecycle.
public struct HTTPResponseNode<Failure: Sendable>: Sendable {
    /// The response head and invocation-relative delay to its receipt.
    public let head: HTTPTimed<HTTPResponseHead>
    /// Complete content or an observed prefix, with exactly one conclusion.
    public let body: HTTPBodyDelivery<Failure>

    /// Builds a response with bounded invocation-relative timing, regardless of status.
    public init(head: HTTPTimed<HTTPResponseHead>, body: HTTPBodyDelivery<Failure>) throws {
        _ = try HTTPDelay.add(head.after.milliseconds.value, body.durationMilliseconds)
        self.head = head
        self.body = body
    }
}

/// Exact response content appears once, independently of how delivery concludes.
public struct HTTPBodyDelivery<Failure: Sendable>: Sendable {
    /// Complete returned content, or only the prefix observed before failure/open.
    public var content: HTTPResponseBody {
        switch storage {
        case let .unprofiled(content): content
        case let .bytes(bytes, _): .bytes(bytes)
        case let .resource(resource, _): .resource(resource)
        }
    }

    /// Optional weighted delivery shape, permitted only for byte or resource content.
    public var profile: HTTPBodyProfile? {
        switch storage {
        case .unprofiled: nil
        case let .bytes(_, profile), let .resource(_, profile): profile
        }
    }

    /// A single leaf owns completion, failure, or an explicit recording horizon.
    public let conclusion: HTTPBodyConclusion<Failure>

    let durationMilliseconds: Int64
    private let storage: Storage

    private enum Storage: Equatable, Sendable {
        case unprofiled(HTTPResponseBody)
        case bytes([UInt8], HTTPBodyProfile)
        case resource(HTTPBodyResource, HTTPBodyProfile)
    }

    /// Builds body delivery; unavailable content never implies empty bytes.
    public init(content: HTTPResponseBody, conclusion: HTTPBodyConclusion<Failure>) {
        storage = .unprofiled(content)
        durationMilliseconds = conclusion.durationMilliseconds
        self.conclusion = conclusion
    }

    /// Builds byte delivery with checked segment-to-conclusion cumulative timing.
    public init(content: HTTPResponseBody, profile: HTTPBodyProfile, conclusion: HTTPBodyConclusion<Failure>) throws {
        switch content {
        case let .bytes(bytes): storage = .bytes(bytes, profile)
        case let .resource(resource): storage = .resource(resource, profile)
        case .absent, .unavailable: throw HTTPLifecycleError.bodyProfileWithoutBytes
        }
        durationMilliseconds = try HTTPDelay.add(profile.durationMilliseconds, conclusion.durationMilliseconds)
        self.conclusion = conclusion
    }
}

/// Mutually exclusive outcomes after a response head and any observed prefix.
public enum HTTPBodyConclusion<Failure: Sendable>: Sendable {
    /// Message delivery succeeds, including responses with HTTP 4xx/5xx status.
    case returned(HTTPBodyCompletion)
    /// A typed failure after the response head and observed prefix.
    case failed(HTTPTimed<Failure>)
    /// No terminal event occurs before the horizon; no completion is synthesized.
    case openAtRecordingHorizon

    var durationMilliseconds: Int64 {
        switch self {
        case let .returned(completion): completion.durationMilliseconds
        case let .failed(failure): failure.after.milliseconds.value
        case .openAtRecordingHorizon: 0
        }
    }
}

/// Successful completion is the only branch permitted to own trailers.
public struct HTTPBodyCompletion: Equatable, Sendable {
    /// Successive delay from trailers, or from the last body event/head if absent.
    public let after: HTTPDelay
    /// Optional observed trailers, delivered before completion.
    public let trailers: HTTPTrailers?

    let durationMilliseconds: Int64

    /// Builds a completion with a checked trailer-to-completion delay sum.
    public init(after: HTTPDelay, trailers: HTTPTrailers? = nil) throws {
        durationMilliseconds = try HTTPDelay.add(trailers?.after.milliseconds.value ?? 0, after.milliseconds.value)
        self.after = after
        self.trailers = trailers
    }
}

/// Ordered repeated trailer fields delivered after the last body event/head.
public struct HTTPTrailers: Equatable, Sendable {
    /// Successive delay before these trailers, distinct from completion's delay.
    public let after: HTTPDelay
    /// HTTP Types fields in memory; Diorama's codec owns their persisted form.
    public let fields: HTTPFields

    /// Builds trailers without changing field spelling, byte values, or order.
    public init(after: HTTPDelay, fields: HTTPFields) {
        self.after = after
        self.fields = fields
    }
}

extension HTTPInteraction: Equatable where Failure: Equatable {}
extension HTTPAttemptResult: Equatable where Failure: Equatable {}
extension HTTPResponseNode: Equatable where Failure: Equatable {}
extension HTTPBodyDelivery: Equatable where Failure: Equatable {}
extension HTTPBodyConclusion: Equatable where Failure: Equatable {}
