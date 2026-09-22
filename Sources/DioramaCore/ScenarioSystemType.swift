/// Optional format-neutral persistence for one system type.
///
/// Systems need not provide this capability, and in-memory execution does not
/// invoke it. Implementations own their deliberate schemas and validation;
/// repositories own transport, registration, and publication.
public protocol ScenarioSystemPersistence: Sendable {
    /// The version emitted by the current writer.
    var currentSchemaVersion: UInt32 { get }

    /// Explicitly supported reader versions in deterministic numeric order.
    var supportedSchemaVersions: [UInt32] { get }

    /// Encodes one strict attachment through the system's current schema.
    /// - Parameters:
    ///   - attachment: Prepared semantic content for this system type.
    ///   - encoder: The transport's payload encoder.
    func encode(_ attachment: ScenarioAttachment, to encoder: any Encoder) throws

    /// Validates a supported payload into one strict semantic attachment.
    /// - Parameters:
    ///   - attachmentID: Exact type and key expected by the document header.
    ///   - version: The explicitly declared payload version.
    ///   - decoder: The transport's payload decoder.
    /// - Returns: Prepared content with the requested identity.
    func decode(attachmentID: AttachmentID, version: UInt32, from decoder: any Decoder) throws -> ScenarioAttachment
}

/// Shared immutable runtime metadata for a system type, independent of its instances.
///
/// Reuse one descriptor across keyed instances. The stable identifier enters
/// scenario data; persistence implementations remain runtime configuration.
/// Reference identity only detects conflicting declarations within setup. It
/// never participates in semantic identity, persistence, or diagnostic ordering.
public final class ScenarioSystemType: Sendable {
    /// Stable semantic identity, independent of this runtime descriptor's lifetime.
    public let id: SystemTypeID

    /// The type's optional persistence capability.
    public let persistence: (any ScenarioSystemPersistence)?

    /// Creates immutable system-wide metadata.
    /// - Parameters:
    ///   - id: Stable owner and semantic kind of the system.
    ///   - persistence: Optional versioned payload reader and writer.
    public init(id: SystemTypeID, persistence: (any ScenarioSystemPersistence)? = nil) {
        self.id = id
        self.persistence = persistence
    }

    /// Creates a descriptor from a stable string identifier.
    /// - Parameters:
    ///   - id: Stable string representation of the system identity.
    ///   - persistence: Optional versioned payload reader and writer.
    public convenience init(_ id: String, persistence: (any ScenarioSystemPersistence)? = nil) {
        self.init(id: SystemTypeID(rawValue: id), persistence: persistence)
    }
}
