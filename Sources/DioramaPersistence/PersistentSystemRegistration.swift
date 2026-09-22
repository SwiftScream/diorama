import DioramaCore

/// A stable persisted-system header independent of its encoded payload.
public struct PersistedSystemDescriptor: Equatable, Sendable {
    /// The scenario-local key for this system instance.
    public let attachmentKey: AttachmentKey

    /// The stable owner and semantic kind of the payload.
    public let systemTypeID: SystemTypeID

    /// The explicitly declared system-payload schema version.
    public let schemaVersion: UInt32

    /// Creates persisted-system dispatch metadata.
    ///
    /// - Parameters:
    ///   - attachmentKey: The scenario-local instance key.
    ///   - systemTypeID: The stable payload owner and semantic kind.
    ///   - schemaVersion: The declared payload schema version.
    public init(
        attachmentKey: AttachmentKey,
        systemTypeID: SystemTypeID,
        schemaVersion: UInt32)
    {
        self.attachmentKey = attachmentKey
        self.systemTypeID = systemTypeID
        self.schemaVersion = schemaVersion
    }

    /// The complete stable attachment identity described by this header.
    public var attachmentID: AttachmentID {
        AttachmentID(systemTypeID: systemTypeID, key: attachmentKey)
    }
}

/// A Codable implementation of a system type's optional persistence capability.
///
/// Attach this capability to a shared `ScenarioSystemType`. It contains no
/// duplicated system identifier or execution state. Decoders must validate and admit
/// their already-prepared payload before returning a strict
/// ``DioramaCore/ScenarioAttachment``.
public struct PersistentSystemRegistration: ScenarioSystemPersistence {
    typealias Reader = @Sendable (
        AttachmentKey,
        any Decoder) throws -> ScenarioAttachment

    /// The schema version emitted by this registration's writer.
    public let currentSchemaVersion: UInt32

    /// Reader versions in deterministic numeric order.
    public var supportedSchemaVersions: [UInt32] {
        readers.keys.sorted()
    }

    private let writer: @Sendable (
        ScenarioAttachment,
        any Encoder) throws -> Void
    private let readers: [UInt32: Reader]

    /// Creates a registration with a current `Codable` payload reader/writer.
    ///
    /// The payload type is a deliberate persisted representation owned by the
    /// system. `decode` must validate already-prepared values before constructing
    /// the returned attachment, without rerunning capture transformations or
    /// reporting through a synthetic scenario. The registry later verifies that
    /// its complete identity matches the persisted descriptor.
    ///
    /// - Parameters:
    ///   - currentSchemaVersion: The version emitted by the current writer.
    ///   - payloadType: The current deliberate `Codable` payload type.
    ///   - encode: Converts one strict semantic attachment into current payload.
    ///   - decode: Validates and admits current payload as one strict attachment.
    public init<Payload: Codable & Sendable>(
        currentSchemaVersion: UInt32,
        payloadType _: Payload.Type = Payload.self,
        encode: @escaping @Sendable (ScenarioAttachment) throws -> Payload,
        decode: @escaping @Sendable (Payload, AttachmentKey) throws -> ScenarioAttachment)
    {
        self.currentSchemaVersion = currentSchemaVersion
        writer = { attachment, encoder in
            try encode(attachment).encode(to: encoder)
        }
        readers = [
            currentSchemaVersion: { key, decoder in
                try decode(Payload(from: decoder), key)
            },
        ]
    }

    private init(
        currentSchemaVersion: UInt32,
        writer: @escaping @Sendable (
            ScenarioAttachment,
            any Encoder) throws -> Void,
        readers: [UInt32: Reader])
    {
        self.currentSchemaVersion = currentSchemaVersion
        self.writer = writer
        self.readers = readers
    }

    /// Returns a registration that also reads one historical payload version.
    ///
    /// Historical decoding converts in memory and never writes or mutates its
    /// source. The current writer remains unchanged.
    ///
    /// - Parameters:
    ///   - version: An additional explicitly supported historical version.
    ///   - payloadType: Its deliberate `Decodable` representation.
    ///   - decode: Validates and admits historical payload as one current attachment.
    /// - Returns: A new immutable registration with the additional reader.
    /// - Throws: ``PersistenceRegistrationError/duplicateReader(version:)``
    ///   if the version already has a reader.
    public func addingReader<Payload: Decodable & Sendable>(
        for version: UInt32,
        payloadType _: Payload.Type = Payload.self,
        decode: @escaping @Sendable (Payload, AttachmentKey) throws -> ScenarioAttachment)
        throws(PersistenceRegistrationError) -> PersistentSystemRegistration
    {
        guard readers[version] == nil else {
            throw .duplicateReader(version: version)
        }
        var readers = readers
        readers[version] = { key, decoder in
            try decode(Payload(from: decoder), key)
        }
        return PersistentSystemRegistration(
            currentSchemaVersion: currentSchemaVersion,
            writer: writer,
            readers: readers)
    }

    /// Encodes prepared attachment content using the current writer.
    public func encode(
        _ attachment: ScenarioAttachment,
        to encoder: any Encoder) throws
    {
        try writer(attachment, encoder)
    }

    /// Decodes and validates one supported payload for the requested identity.
    public func decode(
        attachmentID: AttachmentID,
        version: UInt32,
        from decoder: any Decoder) throws -> ScenarioAttachment
    {
        guard let reader = readers[version] else {
            throw PersistenceDispatchError.unsupportedSchemaVersion(
                systemTypeID: attachmentID.systemTypeID,
                declared: version,
                supported: supportedSchemaVersions)
        }
        return try reader(attachmentID.key, decoder)
    }
}

/// Invalid immutable registration construction evidence.
public enum PersistenceRegistrationError: Error, Equatable, Sendable {
    /// More than one registry entry claims the same stable system type.
    case duplicateSystemType(SystemTypeID)

    /// A system descriptor supplies no persistence capability.
    case missingPersistence(SystemTypeID)

    /// More than one reader claims the same system-payload version.
    case duplicateReader(version: UInt32)
}
