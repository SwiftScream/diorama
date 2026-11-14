import HTTPTypes

/// A transport-neutral request with complete content and an HTTP Types head.
public struct HTTPRequestMessage: Hashable, Sendable {
    /// Version-independent method, target, and ordered repeated fields.
    public let head: HTTPRequest
    /// Whether persistence resolves Content-Length from the body instead of a literal.
    public let derivesContentLength: Bool

    /// Complete request content, retaining absent versus empty semantics.
    public let body: HTTPRequestBody

    /// Builds a message without native Foundation wrappers or filesystem access.
    ///
    /// Extended CONNECT is unsupported. Target pseudo-fields must be UTF-8 so
    /// encoding never silently repairs their bytes. Header values preserve bytes.
    public init(head: HTTPRequest, body: HTTPRequestBody = .absent) throws {
        try self.init(head: head, body: body, derivesContentLength: false)
    }

    init(head: HTTPRequest, body: HTTPRequestBody, derivesContentLength: Bool) throws {
        guard head.extendedConnectProtocol == nil else { throw HTTPMessageError.unsupportedRequest }
        for field in [head.pseudoHeaderFields.scheme, head.pseudoHeaderFields.authority, head.pseudoHeaderFields.path] {
            if let field {
                guard field.withUnsafeBytesOfValue({ Array($0) }) == Array(field.value.utf8) else {
                    throw HTTPMessageError.invalidField
                }
            }
        }
        self.head = head
        self.body = body
        self.derivesContentLength = derivesContentLength
    }

    init(_ message: Self, derivesContentLength: Bool) {
        head = message.head
        body = message.body
        self.derivesContentLength = derivesContentLength
    }
}

/// A response head without body or lifecycle conclusions.
///
/// Response bodies belong to response-owned lifecycle nodes, introduced separately.
public struct HTTPResponseHead: Hashable, Sendable {
    /// Version-independent status, reason phrase, and ordered repeated fields.
    public let head: HTTPResponse

    /// Whether persistence resolves Content-Length from the response body.
    public let derivesContentLength: Bool

    /// Builds a response head without inventing a wire protocol version.
    public init(head: HTTPResponse) {
        self.init(head: head, derivesContentLength: false)
    }

    init(head: HTTPResponse, derivesContentLength: Bool) {
        self.head = head
        self.derivesContentLength = derivesContentLength
    }
}
