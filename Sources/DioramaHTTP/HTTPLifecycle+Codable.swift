import DioramaPersistence
import HTTPTypes

extension HTTPInteraction: Codable where Failure: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case initialRequest, result }

    /// Reads one complete root request and exactly one validated result.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        try self.init(initialRequest: fields.decode(HTTPRequestMessage.self, forKey: .initialRequest),
                      result: fields.decode(HTTPAttemptResult<Failure>.self, forKey: .result))
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
    private enum CodingKeys: String, CodingKey, CaseIterable { case head, body }

    /// Reads a response with one head and its body lifecycle.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        try self.init(head: fields.decode(HTTPTimed<HTTPResponseHead>.self, forKey: .head),
                      body: fields.decode(HTTPBodyDelivery<Failure>.self, forKey: .body))
    }

    /// Writes response-owned content once.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(head, forKey: .head)
        try fields.encode(body, forKey: .body)
    }
}

extension HTTPBodyDelivery: Codable where Failure: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case content, conclusion }

    /// Reads content and one required conclusion; truncation is never implicit open.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        try self.init(content: fields.decode(HTTPResponseBody.self, forKey: .content),
                      conclusion: fields.decode(HTTPBodyConclusion<Failure>.self, forKey: .conclusion))
    }

    /// Writes complete content or a partial prefix, never a competing second body.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(content, forKey: .content)
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
        try self.init(after: fields.decode(HTTPDelay.self, forKey: .after),
                      trailers: fields.contains(.trailers) ? fields.decode(HTTPTrailers.self, forKey: .trailers) : nil)
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
                      fields: HTTPFields(container.decode([FieldPayload].self, forKey: .fields).map { try $0.field() }))
    }

    /// Writes literal trailer fields in semantic order and one successive delay.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(after, forKey: .after)
        try container.encode(fields.map(FieldPayload.init), forKey: .fields)
    }
}

private enum HTTPLifecycleTag: String, CodingKey, CaseIterable { case kind }
