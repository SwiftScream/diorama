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
    private enum RefusedKeys: String, CodingKey, CaseIterable { case kind, body }

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
            self = try .refuse(fields.decode(HTTPBodyDelivery<Failure>.self, forKey: .body))
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
        case let .refuse(body):
            var fields = encoder.container(keyedBy: RefusedKeys.self)
            try fields.encode("refuse", forKey: .kind)
            try fields.encode(body, forKey: .body)
        case .openAtRecordingHorizon:
            var fields = encoder.container(keyedBy: Tag.self)
            try fields.encode("open", forKey: .kind)
        }
    }
}
