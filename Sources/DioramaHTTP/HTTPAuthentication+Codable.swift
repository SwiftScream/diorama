import DioramaPersistence

extension HTTPAuthenticationMethod: Codable {
    /// Reads a supported method without rendering an unknown value.
    public init(from decoder: any Decoder) throws {
        let field = try decoder.singleValueContainer()
        guard let value = try Self(rawValue: field.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: field, debugDescription: "Unsupported authentication method")
        }
        self = value
    }

    /// Writes the deliberate portable method spelling.
    public func encode(to encoder: any Encoder) throws {
        var field = encoder.singleValueContainer()
        try field.encode(rawValue)
    }
}

extension HTTPAuthenticationPersistence: Codable {
    /// Reads a supported persistence without rendering an unknown value.
    public init(from decoder: any Decoder) throws {
        let field = try decoder.singleValueContainer()
        guard let value = try Self(rawValue: field.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: field,
                debugDescription: "Unsupported authentication persistence")
        }
        self = value
    }

    /// Writes the deliberate portable persistence spelling.
    public func encode(to encoder: any Encoder) throws {
        var field = encoder.singleValueContainer()
        try field.encode(rawValue)
    }
}

extension HTTPAuthenticationCredential: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case user, hasPassword, persistence }

    /// Reads only safe shape fields; passwords and unknown credential material fail decoding.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        try self.init(user: fields.contains(.user) ? fields.decode(String.self, forKey: .user) : nil,
                      hasPassword: fields.decode(Bool.self, forKey: .hasPassword),
                      persistence: fields.decode(HTTPAuthenticationPersistence.self, forKey: .persistence))
    }

    /// Writes identity metadata with no password field or native storage reference.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encodeIfPresent(user, forKey: .user)
        try fields.encode(hasPassword, forKey: .hasPassword)
        try fields.encode(persistence, forKey: .persistence)
    }
}

extension HTTPAuthenticationChallenge: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case method, host, port, `protocol`, realm, isProxy, previousFailureCount, proposedCredential
    }

    /// Validates detached protection-space metadata without reapplying preparation.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        let method = try fields.decode(HTTPAuthenticationMethod.self, forKey: .method)
        let host = try fields.decode(String.self, forKey: .host)
        let port = try fields.decode(Int.self, forKey: .port)
        let count = try fields.decode(Int.self, forKey: .previousFailureCount)
        guard !host.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .host,
                in: fields,
                debugDescription: "Invalid authentication host")
        }
        guard (0...65535).contains(port) else {
            throw DecodingError.dataCorruptedError(
                forKey: .port,
                in: fields,
                debugDescription: "Invalid authentication port")
        }
        guard count >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .previousFailureCount, in: fields, debugDescription: "Invalid authentication failure count")
        }
        try self.init(method: method, host: host, port: port,
                      protocol: fields.contains(.protocol) ? fields.decode(String.self, forKey: .protocol) : nil,
                      realm: fields.contains(.realm) ? fields.decode(String.self, forKey: .realm) : nil,
                      isProxy: fields.decode(Bool.self, forKey: .isProxy), previousFailureCount: count,
                      proposedCredential: fields.contains(.proposedCredential)
                          ? fields.decode(HTTPAuthenticationCredential.self, forKey: .proposedCredential) : nil)
    }

    /// Writes one challenge without repeating the owning 401/407 response.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(method, forKey: .method)
        try fields.encode(host, forKey: .host)
        try fields.encode(port, forKey: .port)
        try fields.encodeIfPresent(`protocol`, forKey: .protocol)
        try fields.encodeIfPresent(realm, forKey: .realm)
        try fields.encode(isProxy, forKey: .isProxy)
        try fields.encode(previousFailureCount, forKey: .previousFailureCount)
        try fields.encodeIfPresent(proposedCredential, forKey: .proposedCredential)
    }
}

extension HTTPAuthenticationPhase: Codable where Failure: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case after, challenge, outcome }

    /// Reads the presentation delay and sole recorded decision.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        try self.init(after: fields.decode(HTTPDelay.self, forKey: .after),
                      challenge: fields.decode(HTTPAuthenticationChallenge.self, forKey: .challenge),
                      outcome: fields.decode(HTTPAuthenticationOutcome<Failure>.self, forKey: .outcome))
    }

    /// Writes local timing without application decision latency.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(after, forKey: .after)
        try fields.encode(challenge, forKey: .challenge)
        try fields.encode(outcome, forKey: .outcome)
    }
}

extension HTTPAuthenticationRetry: Codable where Failure: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case request, result }

    /// Absence of request inherits it; explicit null is not an inheritance spelling.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        try self.init(
            request: fields.contains(.request) ? fields.decode(HTTPRequestMessage.self, forKey: .request) : nil,
            result: fields.decode(HTTPAttemptResult<Failure>.self, forKey: .result))
    }

    /// Writes a request only for a material change that cannot be derived.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encodeIfPresent(request, forKey: .request)
        try fields.encode(result, forKey: .result)
    }
}

extension HTTPAuthenticationOutcome: Codable where Failure: Codable {
    private enum Tag: String, CodingKey, CaseIterable { case kind }
    private enum UseKeys: String, CodingKey, CaseIterable { case kind, credential, retry }
    private enum NextKeys: String, CodingKey, CaseIterable { case kind, continuation }
    private enum CancelKeys: String, CodingKey, CaseIterable { case kind, failure }

    /// Reads only fields belonging to the selected disposition.
    public init(from decoder: any Decoder) throws {
        let tag = try decoder.container(keyedBy: Tag.self)
        switch try tag.decode(String.self, forKey: .kind) {
        case "useCredential":
            let fields = try decoder.strictContainer(keyedBy: UseKeys.self)
            self = try .useCredential(fields.decode(HTTPAuthenticationCredential.self, forKey: .credential),
                                      fields.decode(HTTPAuthenticationRetry<Failure>.self, forKey: .retry))
        case "performDefaultHandling", "rejectProtectionSpace":
            let fields = try decoder.strictContainer(keyedBy: NextKeys.self)
            let next = try fields.decode(HTTPAuthenticationContinuation<Failure>.self, forKey: .continuation)
            self = try tag.decode(String.self, forKey: .kind) == "performDefaultHandling"
                ? .performDefaultHandling(next) : .rejectProtectionSpace(next)
        case "cancel":
            let fields = try decoder.strictContainer(keyedBy: CancelKeys.self)
            self = try .cancel(fields.decode(HTTPTimed<Failure>.self, forKey: .failure))
        case "open":
            _ = try decoder.strictContainer(keyedBy: Tag.self)
            self = .openAtRecordingHorizon
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: tag, debugDescription: "Unknown HTTP authentication outcome tag")
        }
    }

    /// Writes a single answer; cancellation owns its failure exactly once.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .useCredential(credential, retry):
            var fields = encoder.container(keyedBy: UseKeys.self)
            try fields.encode("useCredential", forKey: .kind)
            try fields.encode(credential, forKey: .credential)
            try fields.encode(retry, forKey: .retry)
        case let .performDefaultHandling(next), let .rejectProtectionSpace(next):
            var fields = encoder.container(keyedBy: NextKeys.self)
            let kind = if case .performDefaultHandling = self {
                "performDefaultHandling"
            } else {
                "rejectProtectionSpace"
            }
            try fields.encode(kind, forKey: .kind)
            try fields.encode(next, forKey: .continuation)
        case let .cancel(failure):
            var fields = encoder.container(keyedBy: CancelKeys.self)
            try fields.encode("cancel", forKey: .kind)
            try fields.encode(failure, forKey: .failure)
        case .openAtRecordingHorizon:
            var fields = encoder.container(keyedBy: Tag.self)
            try fields.encode("open", forKey: .kind)
        }
    }
}

extension HTTPAuthenticationContinuation: Codable where Failure: Codable {
    private enum Tag: String, CodingKey, CaseIterable { case kind }
    private enum RetryKeys: String, CodingKey, CaseIterable { case kind, retry }
    private enum BodyKeys: String, CodingKey, CaseIterable { case kind, body }
    private enum FailedKeys: String, CodingKey, CaseIterable { case kind, failure }

    /// Validates retry, owning-response body, failure, or explicit open progress.
    public init(from decoder: any Decoder) throws {
        let tag = try decoder.container(keyedBy: Tag.self)
        switch try tag.decode(String.self, forKey: .kind) {
        case "retry":
            let fields = try decoder.strictContainer(keyedBy: RetryKeys.self)
            self = try .retry(fields.decode(HTTPAuthenticationRetry<Failure>.self, forKey: .retry))
        case "deliverBody":
            let fields = try decoder.strictContainer(keyedBy: BodyKeys.self)
            self = try .deliverBody(fields.decode(HTTPBodyDelivery<Failure>.self, forKey: .body))
        case "failed":
            let fields = try decoder.strictContainer(keyedBy: FailedKeys.self)
            self = try .failed(fields.decode(HTTPTimed<Failure>.self, forKey: .failure))
        case "open":
            _ = try decoder.strictContainer(keyedBy: Tag.self)
            self = .openAtRecordingHorizon
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: tag, debugDescription: "Unknown HTTP authentication continuation tag")
        }
    }

    /// Writes no competing response, request root, or independent conclusion.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .retry(retry):
            var fields = encoder.container(keyedBy: RetryKeys.self)
            try fields.encode("retry", forKey: .kind)
            try fields.encode(retry, forKey: .retry)
        case let .deliverBody(body):
            var fields = encoder.container(keyedBy: BodyKeys.self)
            try fields.encode("deliverBody", forKey: .kind)
            try fields.encode(body, forKey: .body)
        case let .failed(failure):
            var fields = encoder.container(keyedBy: FailedKeys.self)
            try fields.encode("failed", forKey: .kind)
            try fields.encode(failure, forKey: .failure)
        case .openAtRecordingHorizon:
            var fields = encoder.container(keyedBy: Tag.self)
            try fields.encode("open", forKey: .kind)
        }
    }
}
