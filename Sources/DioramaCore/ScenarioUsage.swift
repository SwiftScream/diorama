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
    }

    /// Every unclaimed replay identity, in stable sequence order.
    ///
    /// Successful sequential claims complete synchronously. Record and
    /// passthrough tracks have no replay cursor.
    public var unusedRecords: [RecordIdentity] {
        guard case let .replay(used, unused) = activity else { return [] }
        return (used..<(used + unused)).map { RecordIdentity(trackID: id, sequence: $0) }
    }
}

/// Ordered facts for one active system attachment.
public struct AttachmentUsage: Equatable, Sendable {
    /// The system instance whose facts are retained.
    public let attachmentID: AttachmentID
    /// The active mode.
    public let mode: ScenarioMode
    /// Whether this attachment allows unused replay records during evaluation.
    ///
    /// This does not suppress operation diagnostics, health, preparation, or
    /// cleanup, and does not waive persistence validation.
    public let allowsUnusedReplayRecords: Bool
    /// Track facts in declaration order, without their recorded values.
    public let tracks: [SequentialTrackUsage]
}

/// Setup and finalization facts beyond individual sequential operations.
public enum VerificationIssue: Equatable, Sendable {
    /// An observation reserved before closure never entered the recording.
    case recordingNotAdmitted
}
