/// Value-free inventory of a prepared in-memory track with no active system.
///
/// This is verification metadata, not a persistence container. A repository
/// must still decode, prepare, and validate content before deriving inventory.
public struct UnattachedTrack: Equatable, Sendable {
    /// The recorded track's stable identity.
    public let id: TrackID
    /// The number of prepared records in the track, including zero.
    public let recordCount: UInt64

    /// Copies identity and count without retaining the track's values.
    ///
    /// - Parameter track: Already prepared in-memory recorded content.
    public init(_ track: SequentialTrack<some Sendable>) {
        id = track.id
        recordCount = UInt64(track.records.count)
    }
}

/// Immutable sequential activity captured when a lease closes.
public struct SequentialTrackUsage: Equatable, Sendable {
    /// The track whose activity is described.
    public let id: TrackID
    /// Mode-specific facts; only replay has consumption obligations.
    public let activity: Activity

    /// Mutually exclusive sequential recording and consumption facts.
    public enum Activity: Equatable, Sendable {
        /// Successfully admitted observations and reservations left incomplete.
        case record(recordedCount: UInt64, incompleteCount: UInt64)
        /// Successful synchronous claims and the remaining unclaimed suffix.
        case replay(usedCount: UInt64, unusedCount: UInt64)
        /// The attachment never accesses track content.
        case passthrough
        /// Recorded content has no active system to interpret its usage.
        case unattached(recordCount: UInt64)
    }

    /// Every unclaimed replay identity, in stable sequence order.
    ///
    /// Successful sequential claims complete synchronously. Record,
    /// passthrough, and unattached tracks have no replay cursor.
    public var unusedRecords: [RecordIdentity] {
        guard case let .replay(used, unused) = activity else { return [] }
        return (used..<(used + unused)).map { RecordIdentity(trackID: id, sequence: $0) }
    }
}

/// Ordered facts for one active or recorded-only system attachment.
public struct AttachmentUsage: Equatable, Sendable {
    /// The system instance whose facts are retained.
    public let attachmentID: AttachmentID
    /// The active mode, or `nil` when only unattached inventory exists.
    public let mode: ScenarioMode?
    /// Whether unused/unattached verification was explicitly waived at setup.
    ///
    /// Ignoring does not suppress operation diagnostics, health, preparation,
    /// or cleanup, and does not waive persistence validation.
    public let isIgnored: Bool
    /// Track facts in declaration order, without their recorded values.
    public let tracks: [SequentialTrackUsage]
}

/// Setup and finalization facts beyond individual sequential operations.
public enum VerificationIssue: Equatable, Sendable {
    /// Recorded track inventory names an attachment with no active system.
    case unattachedRecording
    /// An observation reserved before closure never entered the recording.
    case recordingNotAdmitted
}
