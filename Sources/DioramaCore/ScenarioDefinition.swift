/// Invalid semantic attachment or track structure.
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

    func removingRecords() -> any AnySequentialTrack
}

private struct SequentialTrackBox<Value: Sendable>: AnySequentialTrack {
    let track: SequentialTrack<Value>

    var id: TrackID {
        track.id
    }

    var valueTypeID: ObjectIdentifier {
        ObjectIdentifier(Value.self)
    }

    func removingRecords() -> any AnySequentialTrack {
        SequentialTrackBox(track: SequentialTrack<Value>(id: track.id))
    }
}

/// An immutable declaration of one system attachment and its typed tracks.
public struct ScenarioAttachment: Sendable {
    /// The stable identity of the attached system instance.
    public let id: AttachmentID

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
    public init(id: AttachmentID) {
        self.id = id
        tracks = []
    }

    private init(id: AttachmentID, tracks: [any AnySequentialTrack]) {
        self.id = id
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

    func removingRecords() -> ScenarioAttachment {
        ScenarioAttachment(
            id: id,
            tracks: tracks.map { $0.removingRecords() })
    }
}

/// Immutable semantic scenario data, independent of runtime configuration.
///
/// A definition contains ordered attachments and prepared tracks. It contains
/// no scenario identity, modes, policies, factories, dependencies, or replay state.
/// Persistence uses explicit registered codecs rather than requiring Codable.
public struct ScenarioDefinition: Sendable {
    /// Prepared attachments in deterministic semantic order.
    public let attachments: [ScenarioAttachment]

    /// Creates a definition after validating unique attachment keys and types.
    ///
    /// - Parameter attachments: Prepared content in semantic order; empty is valid.
    /// - Throws: Duplicate or incompatible attachment identity evidence.
    public init(attachments: [ScenarioAttachment] = []) throws(ScenarioDefinitionError) {
        var typesByKey: [AttachmentKey: SystemTypeID] = [:]
        for attachment in attachments {
            if let existing = typesByKey[attachment.id.key] {
                if existing == attachment.id.systemTypeID {
                    throw .duplicateAttachment(attachment.id)
                }
                throw .incompatibleAttachmentSystem(
                    key: attachment.id.key, existing: existing, proposed: attachment.id.systemTypeID)
            }
            typesByKey[attachment.id.key] = attachment.id.systemTypeID
        }
        self.attachments = attachments
    }

    /// Finds recorded content by its caller-selected attachment key.
    ///
    /// - Parameter key: The key to find.
    /// - Returns: Recorded attachment content, or nil if absent.
    public func attachment(for key: AttachmentKey) -> ScenarioAttachment? {
        attachments.first { $0.id.key == key }
    }

    /// Derives an empty typed layout without modifying this definition.
    ///
    /// - Returns: The same attachment and track order with no recorded values.
    public func removingRecords() -> ScenarioDefinition {
        // Removing values cannot invalidate the already validated identities.
        ScenarioDefinition(validatedAttachments: attachments.map { $0.removingRecords() })
    }

    /// Reconciles authoritative content with this definition's active layout.
    ///
    /// Matching baseline attachments supply their entire stable content.
    /// Missing attachments keep an empty typed layout; callers must separately
    /// refuse missing replay content and diagnose unmatched baseline attachments.
    ///
    /// - Parameter baseline: Validated authoritative scenario content.
    /// - Returns: Content ordered by the active layout, omitting unmatched keys.
    /// - Throws: An attachment key associated with incompatible system types.
    public func replacingBaseline(with baseline: ScenarioDefinition) throws(ScenarioDefinitionError)
        -> ScenarioDefinition
    {
        let active = try attachments.map { configured throws(ScenarioDefinitionError) in
            guard let recorded = baseline.attachment(for: configured.id.key) else {
                return configured.removingRecords()
            }
            guard recorded.id == configured.id else {
                throw .incompatibleAttachmentSystem(
                    key: configured.id.key, existing: configured.id.systemTypeID,
                    proposed: recorded.id.systemTypeID)
            }
            return recorded
        }
        return ScenarioDefinition(validatedAttachments: active)
    }

    private init(validatedAttachments: [ScenarioAttachment]) {
        attachments = validatedAttachments
    }
}
