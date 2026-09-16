import DioramaCore

/// Structured persistence dispatch failures that contain no payload values.
public enum PersistenceDispatchError: Error, Equatable, Sendable {
    /// No persistent-system registration exists for this system type.
    case unknownSystemType(SystemTypeID)

    /// A known system type does not support the declared payload version.
    case unsupportedSchemaVersion(
        systemTypeID: SystemTypeID,
        declared: UInt32,
        supported: [UInt32])

    /// A reader returned content for another system type or attachment key.
    case incompatibleRegistration(expected: AttachmentID, decoded: AttachmentID)
}

/// An immutable collection of persistent-system writers and version readers.
///
/// A registry is optional and lives outside `DioramaCore`. Its presence never
/// changes the ability to construct or execute non-`Codable` in-memory tracks.
public struct PersistentSystemRegistry: Sendable {
    private let registrations: [SystemTypeID: PersistentSystemRegistration]

    /// Creates and validates an immutable registry.
    ///
    /// - Parameter registrations: One registration per stable system type.
    /// - Throws: ``PersistenceRegistrationError/duplicateSystemType(_:)`` when
    ///   two entries claim the same stable identity.
    public init(_ registrations: [PersistentSystemRegistration] = [])
        throws(PersistenceRegistrationError)
    {
        var byType: [SystemTypeID: PersistentSystemRegistration] = [:]
        for registration in registrations {
            guard byType[registration.systemTypeID] == nil else {
                throw .duplicateSystemType(registration.systemTypeID)
            }
            byType[registration.systemTypeID] = registration
        }
        self.registrations = byType
    }

    /// Verifies that every active attachment has a registration.
    ///
    /// Ignored attachments remain subject to this validation. The operation
    /// checks registration availability only; payload conversion occurs when a
    /// complete candidate attachment is encoded.
    ///
    /// - Parameter definition: The strict in-memory definition to validate.
    /// - Throws: ``PersistenceDispatchError/unknownSystemType(_:)`` for the
    ///   first attachment whose system type cannot be persisted.
    public func validatePersistability(of definition: ScenarioDefinition)
        throws(PersistenceDispatchError)
    {
        for attachment in definition.attachments {
            try requireRegistration(for: attachment.id.systemTypeID)
        }
    }

    /// Encodes one strict semantic attachment with its current registered writer.
    ///
    /// - Parameters:
    ///   - attachment: The prepared attachment content to persist.
    ///   - encoder: The enclosing format's payload destination.
    /// - Returns: Stable dispatch metadata to store beside the payload.
    /// - Throws: ``PersistenceDispatchError/unknownSystemType(_:)`` or a
    ///   system-owned safe conversion/encoding error.
    public func encode(
        _ attachment: ScenarioAttachment,
        to encoder: any Encoder) throws -> PersistedSystemDescriptor
    {
        guard let registration = registrations[attachment.id.systemTypeID] else {
            throw PersistenceDispatchError.unknownSystemType(attachment.id.systemTypeID)
        }
        try registration.encode(attachment, to: encoder)
        return PersistedSystemDescriptor(
            attachmentKey: attachment.id.key,
            systemTypeID: attachment.id.systemTypeID,
            schemaVersion: registration.currentSchemaVersion)
    }

    /// Decodes one explicitly typed and versioned payload into current semantics.
    ///
    /// Unknown systems and unsupported versions are rejected before payload
    /// decoding. The selected reader must return the exact attachment identity
    /// described by the persisted metadata.
    ///
    /// - Parameters:
    ///   - descriptor: Stable type, instance key, and declared payload version.
    ///   - decoder: The enclosing format's payload source.
    /// - Returns: Prepared current semantic attachment content.
    /// - Throws: A structured dispatch failure or system-owned safe decoding,
    ///   migration, preparation, or validation evidence.
    public func decode(
        _ descriptor: PersistedSystemDescriptor,
        from decoder: any Decoder) throws -> ScenarioAttachment
    {
        guard let registration = registrations[descriptor.systemTypeID] else {
            throw PersistenceDispatchError.unknownSystemType(descriptor.systemTypeID)
        }
        let attachment = try registration.decode(
            key: descriptor.attachmentKey,
            version: descriptor.schemaVersion,
            from: decoder)
        guard attachment.id == descriptor.attachmentID else {
            throw PersistenceDispatchError.incompatibleRegistration(
                expected: descriptor.attachmentID,
                decoded: attachment.id)
        }
        return attachment
    }

    private func requireRegistration(for systemTypeID: SystemTypeID)
        throws(PersistenceDispatchError)
    {
        guard registrations[systemTypeID] != nil else {
            throw .unknownSystemType(systemTypeID)
        }
    }
}
