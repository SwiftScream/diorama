import DioramaCore
import Foundation

/// Setup and persistence capability for first-party clock attachments.
public enum DioramaClockSystem {
    /// The first-party clock type and its versioned persistence capability.
    public static let type = ScenarioSystemType(
        "diorama.clock", persistence: DioramaClockPersistence.registration)

    private static let wallTrackKey = TrackKey(rawValue: "wall")

    static func trackID(for key: AttachmentKey) -> TrackID {
        TrackID(
            attachmentID: AttachmentID(systemTypeID: type.id, key: key),
            key: wallTrackKey)
    }

    /// Builds an immutable clock attachment from validated wall content.
    static func attachment(
        named name: String,
        recording: WallRecording = .empty) throws -> ScenarioAttachment
    {
        let key = AttachmentKey(rawValue: name)
        let trackID = trackID(for: key)
        let preparation = ValuePreparation<OverridableValue<Date>>()
        let prepared = try recording.effectiveValues.enumerated().map { position, value in
            try preparation.admitPrepared(
                value,
                context: .record(RecordIdentity(trackID: trackID, sequence: UInt64(position))))
        }
        let header = try ValuePreparation<Int?>().admitPrepared(
            recording.offsetMinutes, context: .track(trackID))
        return try ScenarioAttachment(id: trackID.attachmentID).adding(
            SequentialTrack(id: trackID, header: header, values: prepared))
    }

    /// Reconstructs and validates the wall content of a clock attachment.
    static func recording(in attachment: ScenarioAttachment) throws -> WallRecording {
        let trackID = trackID(for: attachment.id.key)
        guard attachment.id == trackID.attachmentID,
              attachment.trackIDs == [trackID],
              let track = try? attachment.track(
                  trackID, as: OverridableValue<Date>.self, header: Int?.self)
        else { throw WallRecordingError.invalidTrackLayout }
        return try WallRecording(
            offsetMinutes: track.header,
            values: track.records.map(\.value))
    }

    /// Creates one named wall clock backed by the platform wall source.
    ///
    /// Record captures the current encoding timezone at activation.
    /// Replay behavior is added by the next clock unit.
    public static func instance(
        named name: String,
        allowsUnclaimedReplayRecords: Bool = false) throws -> ScenarioSystem<any DioramaWallClock>
    {
        try instance(named: name,
                     allowsUnclaimedReplayRecords: allowsUnclaimedReplayRecords)
        {
            SystemWallDateSource()
        }
    }

    /// Creates one named wall clock with an injected live source factory.
    ///
    /// The factory runs only after successful preparation. Each attachment
    /// serializes reads of its source and the corresponding track operations.
    /// Recording selects the current timezone for origin display at activation;
    /// it never changes the absolute `Date` returned to the consumer.
    public static func instance(
        named name: String,
        allowsUnclaimedReplayRecords: Bool = false,
        sourceFactory: @escaping @Sendable () -> some DioramaWallClock)
        throws -> ScenarioSystem<any DioramaWallClock>
    {
        let key = AttachmentKey(rawValue: name)
        let trackID = trackID(for: key)
        let attachment = try attachment(named: name)
        return try ScenarioSystem(type: type, attachment: attachment,
                                  allowsUnclaimedReplayRecords: allowsUnclaimedReplayRecords)
        { context in
            let lease = try context.lease(
                for: trackID, preparation: ValuePreparation<OverridableValue<Date>>(),
                headerPreparation: ValuePreparation<Int?>())
            switch context.mode {
            case .record:
                return PreparedSystem {
                    try lease.setHeader(capturing: { nil }, preparation: ValuePreparation<Int?>())
                    let mode = LiveWallMode.record(WallRecordingState())
                    let clock = LiveWallClock(
                        mode: mode, lease: lease, source: sourceFactory())
                    return ActivatedSystem(
                        dependency: clock as any DioramaWallClock,
                        deactivate: { clock.close() })
                }
            case .passthrough:
                return PreparedSystem {
                    let clock = LiveWallClock(
                        mode: .passthrough, lease: lease, source: sourceFactory())
                    return ActivatedSystem(
                        dependency: clock as any DioramaWallClock,
                        deactivate: { clock.close() })
                }
            case .replay:
                return PreparedSystem {
                    throw ClockActivationError.replayUnavailable
                }
            }
        }
    }
}
