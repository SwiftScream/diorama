/// A configuration error detected before a scenario execution exists.
public enum ScenarioDefinitionError: Error, Equatable, Sendable {
    /// The same attachment was declared more than once.
    case duplicateAttachment(AttachmentID)

    /// One attachment key was associated with two system types.
    case incompatibleAttachmentSystem(
        key: AttachmentKey,
        existing: SystemTypeID,
        proposed: SystemTypeID)

    /// A track was added to an attachment other than the one in its identity.
    case incompatibleTrackAttachment(track: TrackID, expected: AttachmentID)

    /// The same track was declared more than once with one record type.
    case duplicateTrack(TrackID)

    /// The same track identity was used with incompatible record types.
    case incompatibleTrackRecordType(TrackID)
}

private protocol AnySequentialTrack: Sendable {
    var id: TrackID { get }

    /// Runtime type identity validates in-memory generic compatibility only. It
    /// is never used as stable or persisted identity.
    var valueTypeID: ObjectIdentifier { get }
}

private struct SequentialTrackBox<Value: Sendable>: AnySequentialTrack {
    let track: SequentialTrack<Value>

    var id: TrackID {
        track.id
    }

    var valueTypeID: ObjectIdentifier {
        ObjectIdentifier(Value.self)
    }
}

/// An immutable declaration of one system attachment and its typed tracks.
public struct ScenarioAttachment: Sendable {
    /// The stable identity of the attached system instance.
    public let id: AttachmentID

    /// An optional mode for this whole attachment.
    ///
    /// A value here overrides the containing scenario's default. Individual
    /// tracks cannot select different modes.
    public let modeOverride: ScenarioMode?

    private let tracks: [any AnySequentialTrack]

    /// Track identities in their deterministic declaration order.
    public var trackIDs: [TrackID] {
        tracks.map(\.id)
    }

    /// Creates an attachment without tracks.
    ///
    /// Add tracks with ``adding(_:)``. Each addition returns another immutable
    /// value.
    ///
    /// - Parameters:
    ///   - id: The stable attachment identity.
    ///   - modeOverride: A mode for the entire attachment, or `nil` to inherit
    ///     the scenario default.
    public init(id: AttachmentID, modeOverride: ScenarioMode? = nil) {
        self.id = id
        self.modeOverride = modeOverride
        tracks = []
    }

    private init(id: AttachmentID, modeOverride: ScenarioMode?, tracks: [any AnySequentialTrack]) {
        self.id = id
        self.modeOverride = modeOverride
        self.tracks = tracks
    }

    /// Returns a new attachment containing one additional typed track.
    ///
    /// - Parameter track: The track to add in declaration order.
    /// - Returns: A new attachment preserving all previously declared tracks.
    /// - Throws: ``ScenarioDefinitionError`` when the identity belongs to a
    ///   different attachment or collides with an existing track.
    public func adding<Value: Sendable>(_ track: SequentialTrack<Value>) throws -> ScenarioAttachment {
        guard track.id.attachmentID == id else {
            throw ScenarioDefinitionError.incompatibleTrackAttachment(
                track: track.id,
                expected: id)
        }

        if let existing = tracks.first(where: { $0.id == track.id }) {
            if existing.valueTypeID == ObjectIdentifier(Value.self) {
                throw ScenarioDefinitionError.duplicateTrack(track.id)
            }
            throw ScenarioDefinitionError.incompatibleTrackRecordType(track.id)
        }

        return ScenarioAttachment(
            id: id,
            modeOverride: modeOverride,
            tracks: tracks + [SequentialTrackBox(track: track)])
    }

    /// Returns typed content for a track in this attachment.
    ///
    /// - Parameters:
    ///   - id: The stable track identity to find.
    ///   - as: The expected stable value type.
    /// - Returns: The track, or `nil` when this attachment does not declare the
    ///   identity.
    /// - Throws: ``ScenarioDefinitionError/incompatibleTrackRecordType(_:)``
    ///   when the identity exists with another value type, or
    ///   ``ScenarioDefinitionError/incompatibleTrackAttachment(track:expected:)``
    ///   when the identity belongs to another attachment.
    public func track<Value: Sendable>(_ id: TrackID, as _: Value.Type) throws -> SequentialTrack<Value>? {
        guard id.attachmentID == self.id else {
            throw ScenarioDefinitionError.incompatibleTrackAttachment(
                track: id,
                expected: self.id)
        }
        guard let track = tracks.first(where: { $0.id == id }) else {
            return nil
        }
        guard let box = track as? SequentialTrackBox<Value> else {
            throw ScenarioDefinitionError.incompatibleTrackRecordType(id)
        }
        return box.track
    }
}

/// Reusable, immutable configuration for independently created executions.
///
/// A definition contains no replay cursor, working recording, native adapter,
/// or other per-execution mutable state.
public struct ScenarioDefinition: Sendable {
    /// The stable scenario identity.
    public let id: ScenarioID

    /// The mode inherited by attachments without an override.
    public let defaultMode: ScenarioMode

    /// System attachments in deterministic setup order.
    public let attachments: [ScenarioAttachment]

    /// Creates and validates an immutable scenario definition.
    ///
    /// An empty attachment array is valid. Attachment keys are unique across
    /// the scenario even when their system types differ.
    ///
    /// - Parameters:
    ///   - id: The stable scenario identity.
    ///   - defaultMode: The mode inherited by attachments without an override.
    ///   - attachments: System declarations in deterministic setup order.
    /// - Throws: ``ScenarioDefinitionError`` for duplicate or incompatible
    ///   attachment identity.
    public init(id: ScenarioID, defaultMode: ScenarioMode, attachments: [ScenarioAttachment] = []) throws {
        var attachmentByKey: [AttachmentKey: AttachmentID] = [:]
        for attachment in attachments {
            if let existing = attachmentByKey[attachment.id.key] {
                if existing == attachment.id {
                    throw ScenarioDefinitionError.duplicateAttachment(attachment.id)
                }
                throw ScenarioDefinitionError.incompatibleAttachmentSystem(
                    key: attachment.id.key,
                    existing: existing.systemTypeID,
                    proposed: attachment.id.systemTypeID)
            }
            attachmentByKey[attachment.id.key] = attachment.id
        }

        self.id = id
        self.defaultMode = defaultMode
        self.attachments = attachments
    }

    /// Finds an attachment by its caller-selected key.
    ///
    /// - Parameter key: The attachment key to find.
    /// - Returns: The declaration, or `nil` when the key is not configured.
    public func attachment(for key: AttachmentKey) -> ScenarioAttachment? {
        attachments.first { $0.id.key == key }
    }

    /// Resolves the effective whole-attachment mode.
    ///
    /// - Parameter key: The key of the configured attachment.
    /// - Returns: Its override or the scenario default, or `nil` when no such
    ///   attachment is configured.
    public func effectiveMode(for key: AttachmentKey) -> ScenarioMode? {
        attachment(for: key).map { $0.modeOverride ?? defaultMode }
    }
}
