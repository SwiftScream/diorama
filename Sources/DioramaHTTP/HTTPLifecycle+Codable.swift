import DioramaPersistence
import HTTPTypes

extension HTTPInteraction: Codable where Failure: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case initialRequest, result }

    /// Reads one complete root request and exactly one validated result.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        let request = try fields.decode(HTTPRequestMessage.self, forKey: .initialRequest)
        let result = try fields.decode(HTTPAttemptResult<Failure>.self, forKey: .result)
        try result.validateRequestMethod(request.head.method, codingPath: decoder.codingPath + [CodingKeys.result])
        try self.init(initialRequest: request, result: result)
    }

    /// Writes the root without an independent, potentially contradictory conclusion.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(initialRequest, forKey: .initialRequest)
        try fields.encode(result, forKey: .result)
    }
}

extension HTTPAttemptResult: Codable where Failure: Codable {
    private enum ReceivedKeys: String, CodingKey, CaseIterable { case kind, response }
    private enum FailedKeys: String, CodingKey, CaseIterable { case kind, failure }

    /// Reads a recognized result tag and only the fields belonging to that case.
    public init(from decoder: any Decoder) throws {
        let tag = try decoder.container(keyedBy: HTTPLifecycleTag.self)
        switch try tag.decode(String.self, forKey: .kind) {
        case "received":
            let fields = try decoder.strictContainer(keyedBy: ReceivedKeys.self)
            self = try .received(fields.decode(HTTPResponseNode<Failure>.self, forKey: .response))
        case "failed":
            let fields = try decoder.strictContainer(keyedBy: FailedKeys.self)
            self = try .failed(fields.decode(HTTPTimed<Failure>.self, forKey: .failure))
        case "open":
            _ = try decoder.strictContainer(keyedBy: HTTPLifecycleTag.self)
            self = .openAtRecordingHorizon
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: tag, debugDescription: "Unknown HTTP attempt result tag")
        }
    }

    /// Writes one tagged case without redundant lifecycle state.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .received(response):
            var fields = encoder.container(keyedBy: ReceivedKeys.self)
            try fields.encode("received", forKey: .kind)
            try fields.encode(response, forKey: .response)
        case let .failed(failure):
            var fields = encoder.container(keyedBy: FailedKeys.self)
            try fields.encode("failed", forKey: .kind)
            try fields.encode(failure, forKey: .failure)
        case .openAtRecordingHorizon:
            var fields = encoder.container(keyedBy: HTTPLifecycleTag.self)
            try fields.encode("open", forKey: .kind)
        }
    }
}

extension HTTPResponseNode: Codable where Failure: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case head, next }
    private enum HeadKeys: String, CodingKey, CaseIterable { case after, value }

    /// Reads one head and exactly one response-owned body or decision branch.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        let next = try fields.decode(HTTPAfterResponseHead<Failure>.self, forKey: .next)
        let timed = try fields.superDecoder(forKey: .head).strictContainer(keyedBy: HeadKeys.self)
        let count: Int? = if let body = next.body, case .returned = body.conclusion {
            body.content.byteCount
        } else {
            nil
        }
        let value = try HTTPResponseHead(from: timed.superDecoder(forKey: .value), byteCount: count)
        let head = try HTTPTimed(after: timed.decode(HTTPDelay.self, forKey: .after), value: value)
        do {
            try self.init(head: head, next: next)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .next, in: fields,
                debugDescription: "Invalid HTTP response timing, authentication head, or derived content length")
        }
    }

    /// Writes the head and one explicitly tagged response continuation.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(head, forKey: .head)
        try fields.encode(next, forKey: .next)
    }
}

extension HTTPAfterResponseHead: Codable where Failure: Codable {
    private enum BodyKeys: String, CodingKey, CaseIterable { case kind, body }
    private enum RedirectKeys: String, CodingKey, CaseIterable { case kind, redirect }
    private enum DispositionKeys: String, CodingKey, CaseIterable { case kind, disposition }
    private enum AuthenticationKeys: String, CodingKey, CaseIterable { case kind, authenticate }

    /// Reads exactly one tagged continuation with only its own required payload.
    public init(from decoder: any Decoder) throws {
        let tag = try decoder.container(keyedBy: HTTPLifecycleTag.self)
        switch try tag.decode(String.self, forKey: .kind) {
        case "deliverBody":
            let fields = try decoder.strictContainer(keyedBy: BodyKeys.self)
            self = try .deliverBody(fields.decode(HTTPBodyDelivery<Failure>.self, forKey: .body))
        case "redirect":
            let fields = try decoder.strictContainer(keyedBy: RedirectKeys.self)
            self = try .redirect(fields.decode(HTTPRedirectPhase<Failure>.self, forKey: .redirect))
        case "disposition":
            let fields = try decoder.strictContainer(keyedBy: DispositionKeys.self)
            self = try .disposition(fields.decode(HTTPResponseDispositionPhase<Failure>.self, forKey: .disposition))
        case "authenticate":
            let fields = try decoder.strictContainer(keyedBy: AuthenticationKeys.self)
            self = try .authenticate(fields.decode(HTTPAuthenticationPhase<Failure>.self, forKey: .authenticate))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: tag, debugDescription: "Unknown HTTP response continuation tag")
        }
    }

    /// Writes a deliberate tag and the matching case-specific payload.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .deliverBody(body):
            var fields = encoder.container(keyedBy: BodyKeys.self)
            try fields.encode("deliverBody", forKey: .kind)
            try fields.encode(body, forKey: .body)
        case let .redirect(phase):
            var fields = encoder.container(keyedBy: RedirectKeys.self)
            try fields.encode("redirect", forKey: .kind)
            try fields.encode(phase, forKey: .redirect)
        case let .disposition(phase):
            var fields = encoder.container(keyedBy: DispositionKeys.self)
            try fields.encode("disposition", forKey: .kind)
            try fields.encode(phase, forKey: .disposition)
        case let .authenticate(phase):
            var fields = encoder.container(keyedBy: AuthenticationKeys.self)
            try fields.encode("authenticate", forKey: .kind)
            try fields.encode(phase, forKey: .authenticate)
        }
    }
}

extension HTTPBodyDelivery: Codable where Failure: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case content, segments, conclusion }

    /// Reads content and one required conclusion; truncation is never implicit open.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        let content = try fields.decode(HTTPResponseBody.self, forKey: .content)
        let conclusion = try fields.decode(HTTPBodyConclusion<Failure>.self, forKey: .conclusion)
        if fields.contains(.segments) {
            let profile = try fields.decode(HTTPBodyProfile.self, forKey: .segments)
            do {
                try self.init(content: content, profile: profile, conclusion: conclusion)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .segments, in: fields, debugDescription: "Invalid HTTP body profile or cumulative delay")
            }
        } else {
            self.init(content: content, conclusion: conclusion)
        }
    }

    /// Writes complete content or a partial prefix, never a competing second body.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(content, forKey: .content)
        try fields.encodeIfPresent(profile, forKey: .segments)
        try fields.encode(conclusion, forKey: .conclusion)
    }
}

extension HTTPBodyConclusion: Codable where Failure: Codable {
    private enum ReturnedKeys: String, CodingKey, CaseIterable { case kind, completion }
    private enum FailedKeys: String, CodingKey, CaseIterable { case kind, failure }

    /// Reads exactly one leaf, rejecting conflicting outcomes and misplaced trailers.
    public init(from decoder: any Decoder) throws {
        let tag = try decoder.container(keyedBy: HTTPLifecycleTag.self)
        switch try tag.decode(String.self, forKey: .kind) {
        case "returned":
            let fields = try decoder.strictContainer(keyedBy: ReturnedKeys.self)
            self = try .returned(fields.decode(HTTPBodyCompletion.self, forKey: .completion))
        case "failed":
            let fields = try decoder.strictContainer(keyedBy: FailedKeys.self)
            self = try .failed(fields.decode(HTTPTimed<Failure>.self, forKey: .failure))
        case "open":
            _ = try decoder.strictContainer(keyedBy: HTTPLifecycleTag.self)
            self = .openAtRecordingHorizon
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: tag, debugDescription: "Unknown HTTP body conclusion tag")
        }
    }

    /// Writes trailers only inside a successful completion.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .returned(completion):
            var fields = encoder.container(keyedBy: ReturnedKeys.self)
            try fields.encode("returned", forKey: .kind)
            try fields.encode(completion, forKey: .completion)
        case let .failed(failure):
            var fields = encoder.container(keyedBy: FailedKeys.self)
            try fields.encode("failed", forKey: .kind)
            try fields.encode(failure, forKey: .failure)
        case .openAtRecordingHorizon:
            var fields = encoder.container(keyedBy: HTTPLifecycleTag.self)
            try fields.encode("open", forKey: .kind)
        }
    }
}

extension HTTPBodyCompletion: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case after, trailers }

    /// Reads validated local delays; omitted trailers differ from explicit null.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        let after = try fields.decode(HTTPDelay.self, forKey: .after)
        let trailers = try fields.contains(.trailers) ? fields.decode(HTTPTrailers.self, forKey: .trailers) : nil
        do {
            try self.init(after: after, trailers: trailers)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .after, in: fields,
                debugDescription: "HTTP completion cumulative delay exceeds its scalar range")
        }
    }

    /// Writes completion timing and optional preceding trailers.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(after, forKey: .after)
        try fields.encodeIfPresent(trailers, forKey: .trailers)
    }
}

extension HTTPTrailers: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case after, fields }

    /// Uses Diorama's byte-preserving ordered-field codec rather than HTTPTypes Codable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        try self.init(after: container.decode(HTTPDelay.self, forKey: .after),
                      fields: FieldPayload.decode(from: container, key: .fields).0)
    }

    /// Writes literal trailer fields in semantic order and one successive delay.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(after, forKey: .after)
        try container.encode(fields.map { FieldPayload($0) }, forKey: .fields)
    }
}

private enum HTTPLifecycleTag: String, CodingKey, CaseIterable { case kind }
