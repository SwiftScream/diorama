import DioramaCore
import DioramaPersistence
import Foundation

/// A scenario-relative resource owning exact prepared body bytes, without I/O.
public struct HTTPBodyResource: Hashable, Sendable {
    /// Literal slash-separated path, relative to the scenario's resource root.
    public let path: String

    private let content: [UInt8]

    /// Creates a resource owning prepared bytes independently of execution and storage lifetime.
    public init(path: String, bytes: PreparedValue<[UInt8]>) throws {
        let validated: ScenarioResourcePath
        do { validated = try ScenarioResourcePath(path) } catch { throw HTTPMessageError.invalidResource }
        self.init(path: validated, bytes: bytes)
    }

    /// Returns owned bytes without filesystem access.
    public func bytes() -> [UInt8] {
        content
    }

    init(path: ScenarioResourcePath, bytes: PreparedValue<[UInt8]>) {
        self.path = path.value
        content = bytes.value
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
