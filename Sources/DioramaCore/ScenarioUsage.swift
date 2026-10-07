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
        /// Successful claims and remaining unclaimed records.
        case replay(claimedCount: UInt64, unclaimedCount: UInt64)
        /// The attachment never accesses track content.
        case passthrough
    }

    /// Every unclaimed replay identity, in stable sequence order.
    public let unclaimedRecords: [RecordIdentity]
    /// All claimed records in stable record order. `consumeNext()` records
    /// consumption immediately with zero system-reported replay steps.
    public let claimedRecords: [ReplayClaimUsage]
}

/// Ordered facts for one active system attachment.
public struct AttachmentUsage: Equatable, Sendable {
    /// The system instance whose facts are retained.
    public let attachmentID: AttachmentID
    /// The active mode.
    public let mode: ScenarioMode
    /// Whether this attachment allows unclaimed replay records during evaluation.
    ///
    /// This does not suppress operation diagnostics, health, preparation, or
    /// cleanup, and does not waive persistence validation.
    public let allowsUnclaimedReplayRecords: Bool
    /// Track facts in declaration order, without their recorded values.
    public let tracks: [SequentialTrackUsage]
}

/// Setup and finalization facts beyond individual sequential operations.
public enum VerificationIssue: Equatable, Sendable {
    /// An observation reserved before closure never entered the recording.
    case recordingNotAdmitted
    /// System-owned recording merge or complete-result construction failed.
    case recordingMergeFailed
}
