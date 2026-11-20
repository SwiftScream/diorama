import DioramaPersistence

extension HTTPRedirectPhase: Codable where Failure: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case after, proposedRequest, outcome }

    /// Reads a proposal, presentation delay, and required single recorded outcome.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        try self.init(after: fields.decode(HTTPDelay.self, forKey: .after),
                      proposedRequest: fields.decode(HTTPRequestMessage.self, forKey: .proposedRequest),
                      outcome: fields.decode(HTTPRedirectOutcome<Failure>.self, forKey: .outcome))
    }

    /// Writes the proposal once, without native identity or application decision latency.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(after, forKey: .after)
        try fields.encode(proposedRequest, forKey: .proposedRequest)
        try fields.encode(outcome, forKey: .outcome)
    }
}

extension HTTPRedirectOutcome: Codable where Failure: Codable {
    private enum Tag: String, CodingKey, CaseIterable { case kind }
    private enum FollowKeys: String, CodingKey, CaseIterable { case kind, result }
    private enum ModifiedKeys: String, CodingKey, CaseIterable { case kind, request, result }
    private enum RefusedKeys: String, CodingKey, CaseIterable { case kind, next }

    /// Validates branch-local fields before composing the recursive runtime value.
    public init(from decoder: any Decoder) throws {
        let tag = try decoder.container(keyedBy: Tag.self)
        switch try tag.decode(String.self, forKey: .kind) {
        case "followProposed":
            let fields = try decoder.strictContainer(keyedBy: FollowKeys.self)
            self = try .followProposed(fields.decode(HTTPAttemptResult<Failure>.self, forKey: .result))
        case "followModified":
            let fields = try decoder.strictContainer(keyedBy: ModifiedKeys.self)
            self = try .followModified(fields.decode(HTTPRequestMessage.self, forKey: .request),
                                       fields.decode(HTTPAttemptResult<Failure>.self, forKey: .result))
        case "refuse":
            let fields = try decoder.strictContainer(keyedBy: RefusedKeys.self)
            self = try .refuse(fields.decode(HTTPRedirectRefusal<Failure>.self, forKey: .next))
        case "open":
            _ = try decoder.strictContainer(keyedBy: Tag.self)
            self = .openAtRecordingHorizon
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: tag, debugDescription: "Unknown HTTP redirect outcome tag")
        }
    }

    /// Writes only the effective request that cannot be derived from the proposal.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .followProposed(result):
            var fields = encoder.container(keyedBy: FollowKeys.self)
            try fields.encode("followProposed", forKey: .kind)
            try fields.encode(result, forKey: .result)
        case let .followModified(request, result):
            var fields = encoder.container(keyedBy: ModifiedKeys.self)
            try fields.encode("followModified", forKey: .kind)
            try fields.encode(request, forKey: .request)
            try fields.encode(result, forKey: .result)
        case let .refuse(next):
            var fields = encoder.container(keyedBy: RefusedKeys.self)
            try fields.encode("refuse", forKey: .kind)
            try fields.encode(next, forKey: .next)
        case .openAtRecordingHorizon:
            var fields = encoder.container(keyedBy: Tag.self)
            try fields.encode("open", forKey: .kind)
        }
    }
}

extension HTTPRedirectRefusal: Codable where Failure: Codable {
    private enum Tag: String, CodingKey { case kind }
    private enum BodyKeys: String, CodingKey, CaseIterable { case kind, body }
    private enum DispositionKeys: String, CodingKey, CaseIterable { case kind, disposition }

    /// Reads the single continuation permitted after redirect refusal.
    public init(from decoder: any Decoder) throws {
        let tag = try decoder.container(keyedBy: Tag.self)
        switch try tag.decode(String.self, forKey: .kind) {
        case "deliverBody":
            let fields = try decoder.strictContainer(keyedBy: BodyKeys.self)
            self = try .deliverBody(fields.decode(HTTPBodyDelivery<Failure>.self, forKey: .body))
        case "disposition":
            let fields = try decoder.strictContainer(keyedBy: DispositionKeys.self)
            self = try .disposition(fields.decode(HTTPResponseDispositionPhase<Failure>.self, forKey: .disposition))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: tag, debugDescription: "Unknown HTTP redirect refusal continuation tag")
        }
    }

    /// Writes body delivery or a disposition under the existing response.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .deliverBody(body):
            var fields = encoder.container(keyedBy: BodyKeys.self)
            try fields.encode("deliverBody", forKey: .kind)
            try fields.encode(body, forKey: .body)
        case let .disposition(phase):
            var fields = encoder.container(keyedBy: DispositionKeys.self)
            try fields.encode("disposition", forKey: .kind)
            try fields.encode(phase, forKey: .disposition)
        }
    }
}
