import Foundation

/// A portable scenario-relative reference to logical body bytes, without I/O.
public struct HTTPBodyResource: Hashable, Sendable {
    /// Literal slash-separated path, relative to the scenario's resource root.
    public let path: String

    /// Creates a reference, rejecting empty, absolute, dot, and unsafe components.
    public init(path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw HTTPMessageError.invalidResource }
        self.path = path
    }
}

/// Complete request content; absent and present-but-empty bytes are distinct.
public enum HTTPRequestBody: Hashable, Sendable {
    /// No request body was supplied.
    case absent
    /// Exact application-observed bytes, including an empty body.
    case bytes([UInt8])
    /// Logical bytes stored outside the message document.
    case resource(HTTPBodyResource)
}

/// Response content, independent of its later lifecycle conclusion.
public enum HTTPResponseBody: Hashable, Sendable {
    /// The adapter observed no body.
    case absent
    /// Exact complete bytes or observed prefix, as determined by the lifecycle.
    case bytes([UInt8])
    /// Logical bytes stored outside the message document.
    case resource(HTTPBodyResource)
    /// The adapter could not expose the body for this response branch.
    case unavailable
}

/// Safe validation categories that do not echo message content.
public enum HTTPMessageError: Error, Equatable, Sendable {
    /// The resource is not a portable relative path.
    case invalidResource
    /// A field name, byte value, or target cannot be represented faithfully.
    case invalidField
    /// The request uses an extended CONNECT protocol outside this schema.
    case unsupportedRequest
    /// The method or status is malformed.
    case invalidHead
    /// The body has an unknown tag or incompatible fields.
    case invalidBody
}
