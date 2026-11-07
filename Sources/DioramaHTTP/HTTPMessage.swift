import HTTPTypes

/// A transport-neutral request with complete content and an HTTP Types head.
public struct HTTPRequestMessage: Hashable, Sendable {
    /// Version-independent method, target, and ordered repeated fields.
    public let head: HTTPRequest
    /// Complete request content, retaining absent versus empty semantics.
    public let body: HTTPRequestBody

    /// Builds a message without native Foundation wrappers or filesystem access.
    ///
    /// Extended CONNECT is unsupported. Target pseudo-fields must be UTF-8 so
    /// encoding never silently repairs their bytes. Header values preserve bytes.
    public init(head: HTTPRequest, body: HTTPRequestBody = .absent) throws {
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
    }
}

/// A response head without body or lifecycle conclusions.
///
/// Response bodies belong to response-owned lifecycle nodes, introduced separately.
public struct HTTPResponseHead: Hashable, Sendable {
    /// Version-independent status, reason phrase, and ordered repeated fields.
    public let head: HTTPResponse

    /// Builds a response head without inventing a wire protocol version.
    public init(head: HTTPResponse) {
        self.head = head
    }
}
