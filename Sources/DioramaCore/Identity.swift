/// A stable identifier for a scenario.
public struct ScenarioID: Hashable, RawRepresentable, Sendable {
    /// The stable string representation.
    public let rawValue: String

    /// Creates an identifier from its stable string representation.
    ///
    /// - Parameter rawValue: The value that identifies the scenario.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A stable identifier for a system type.
///
/// Multiple attachments may share a system type while retaining independent
/// attachment, track, and record identities.
public struct SystemTypeID: Hashable, RawRepresentable, Sendable {
    /// The stable string representation.
    public let rawValue: String

    /// Creates an identifier from its stable string representation.
    ///
    /// - Parameter rawValue: The value that identifies the system type.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A caller-selected key for one system attachment in a scenario.
public struct AttachmentKey: Hashable, RawRepresentable, Sendable {
    /// The stable string representation.
    public let rawValue: String

    /// Creates a key from its stable string representation.
    ///
    /// - Parameter rawValue: The value that identifies the attachment.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A stable identifier for one attached system instance.
public struct AttachmentID: Hashable, Sendable {
    /// The stable system type implemented by the attachment.
    public let systemTypeID: SystemTypeID

    /// The caller-selected key for this attachment.
    public let key: AttachmentKey

    /// Creates an attachment identifier.
    ///
    /// - Parameters:
    ///   - systemTypeID: The stable identity of the system implementation.
    ///   - key: The key distinguishing this instance in its scenario.
    public init(systemTypeID: SystemTypeID, key: AttachmentKey) {
        self.systemTypeID = systemTypeID
        self.key = key
    }
}

/// A key for one track owned by an attachment.
public struct TrackKey: Hashable, RawRepresentable, Sendable {
    /// The stable string representation.
    public let rawValue: String

    /// Creates a key from its stable string representation.
    ///
    /// - Parameter rawValue: The value that identifies the track within its attachment.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A stable identifier for one track in an attachment.
public struct TrackID: Hashable, Sendable {
    /// The attachment that owns the track.
    public let attachmentID: AttachmentID

    /// The track's key within its attachment.
    public let key: TrackKey

    /// Creates a track identifier.
    ///
    /// - Parameters:
    ///   - attachmentID: The attachment that owns the track.
    ///   - key: The track's key within that attachment.
    public init(attachmentID: AttachmentID, key: TrackKey) {
        self.attachmentID = attachmentID
        self.key = key
    }
}

/// The complete stable identity of one record.
public struct RecordIdentity: Hashable, Sendable {
    /// The track containing the record.
    public let trackID: TrackID

    /// The record's stable zero-based sequence within the track.
    public let sequence: UInt64

    /// Creates a complete record identity.
    ///
    /// - Parameters:
    ///   - trackID: The track containing the record.
    ///   - sequence: The record's stable zero-based sequence within the track.
    public init(trackID: TrackID, sequence: UInt64) {
        self.trackID = trackID
        self.sequence = sequence
    }
}
