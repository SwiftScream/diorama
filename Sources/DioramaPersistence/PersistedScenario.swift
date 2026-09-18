import DioramaCore

/// A strict semantic scenario document ready for persistence or execution setup.
///
/// Repository identity and runtime modes are setup concerns and do not enter the
/// version-one document. Attachment order remains semantically significant.
public struct PersistedScenario: Sendable {
    /// The only scenario-envelope schema version currently written and read.
    public static let schemaVersion: UInt32 = 1

    /// Prepared system attachments in deterministic semantic order.
    public let attachments: [ScenarioAttachment]

    /// Creates a validated persisted scenario.
    ///
    /// - Parameter attachments: Prepared attachments in semantic order.
    /// - Throws: ``DioramaCore/ScenarioDefinitionError`` when an attachment key
    ///   is repeated or associated with incompatible system types.
    public init(attachments: [ScenarioAttachment] = []) throws(ScenarioDefinitionError) {
        try Self.validate(attachments)
        self.attachments = attachments
    }

    private static func validate(_ attachments: [ScenarioAttachment]) throws(ScenarioDefinitionError) {
        var typesByKey: [AttachmentKey: SystemTypeID] = [:]
        for attachment in attachments {
            if let existing = typesByKey[attachment.id.key] {
                if existing == attachment.id.systemTypeID {
                    throw .duplicateAttachment(attachment.id)
                }
                throw .incompatibleAttachmentSystem(
                    key: attachment.id.key,
                    existing: existing,
                    proposed: attachment.id.systemTypeID)
            }
            typesByKey[attachment.id.key] = attachment.id.systemTypeID
        }
    }
}

/// Safe structural failures for Diorama's persisted scenario object model.
///
/// Coding paths and field names are schema-authored. Payload values and
/// arbitrary decoder descriptions are deliberately excluded.
public enum PersistedScenarioCodingError: Error, Equatable, Sendable {
    /// No explicit Diorama envelope version can be selected.
    case unversionedEnvelope

    /// The envelope declares a version this schema does not read.
    case unsupportedEnvelopeVersion(declared: UInt32, supported: [UInt32])

    /// A strict Diorama-owned structure contains an unrecognized field.
    case unknownField(codingPath: [String], field: String)

    /// Required structure or a scalar has the wrong encoded representation.
    case malformed(codingPath: [String])
}
