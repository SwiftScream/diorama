import DioramaCore
import Foundation

/// Setup and persistence capability for first-party date attachments.
public enum DioramaDateSystem {
    /// The first-party date type and its versioned persistence capability.
    public static let type = ScenarioSystemType(
        "diorama.date", persistence: DioramaDatePersistence.registration)

    private static let wallTrackKey = TrackKey(rawValue: "wall")

    static func trackID(for key: AttachmentKey) -> TrackID {
        TrackID(
            attachmentID: AttachmentID(systemTypeID: type.id, key: key),
            key: wallTrackKey)
    }

    /// Builds an immutable date attachment from validated wall content.
    static func attachment(
        named name: String,
        recording: WallRecording = .empty) throws -> ScenarioAttachment
    {
        let key = AttachmentKey(rawValue: name)
        let trackID = trackID(for: key)
        return try ScenarioAttachment(id: trackID.attachmentID).adding(track(id: trackID, recording: recording))
    }

    /// Creates the same prepared track for authoring and finalization merge.
    static func track(
        id trackID: TrackID,
        recording: WallRecording) throws -> SequentialTrack<OverridableValue<Date>, Int?>
    {
        let preparation = ValuePreparation<OverridableValue<Date>>()
        let prepared = try recording.effectiveValues.enumerated().map { position, value in
            try preparation.admitPrepared(
                value,
                context: .record(RecordIdentity(trackID: trackID, sequence: UInt64(position))))
        }
        let header = try ValuePreparation<Int?>().admitPrepared(
            recording.offsetMinutes, context: .track(trackID))
        return SequentialTrack(id: trackID, header: header, values: prepared)
    }

    /// Reconstructs and validates the wall content of a date attachment.
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

    /// Creates one named date source backed by the platform wall source.
    ///
    /// Record captures the current encoding timezone at activation.
    /// Replay consumes the prepared wall track without activating a live source.
    public static func instance(
        named name: String,
        allowsUnclaimedReplayRecords: Bool = false) throws -> ScenarioSystem<any DioramaDateSource>
    {
        try instance(named: name,
                     allowsUnclaimedReplayRecords: allowsUnclaimedReplayRecords)
        {
            SystemWallDateSource()
        }
    }

    /// Creates one named date source with an injected live source factory.
    ///
    /// The factory runs only after successful preparation. Each attachment
    /// serializes reads of its source and the corresponding track operations.
    /// Recording selects the current timezone for origin display at activation;
    /// it never changes the absolute `Date` returned to the consumer.
    public static func instance(
        named name: String,
        allowsUnclaimedReplayRecords: Bool = false,
        sourceFactory: @escaping @Sendable () -> some DioramaDateSource)
        throws -> ScenarioSystem<any DioramaDateSource>
    {
        let key = AttachmentKey(rawValue: name)
        let trackID = trackID(for: key)
        let attachment = try attachment(named: name)
        return try ScenarioSystem(type: type, attachment: attachment,
                                  allowsUnclaimedReplayRecords: allowsUnclaimedReplayRecords)
        { context in
            let lease = try context.lease(
                for: trackID, preparation: ValuePreparation<OverridableValue<Date>>(),
                headerPreparation: ValuePreparation<Int?>(),
                continuationPolicy: .replayLast(defaultValue: .observed(ReplayDateSource.unixEpoch)),
                mergeRecording: mergeWallRecording)
            switch context.mode {
            case .record:
                return PreparedSystem {
                    try lease.setHeader(capturing: { nil }, preparation: ValuePreparation<Int?>())
                    let mode = LiveWallMode.record(WallRecordingState())
                    let dates = LiveDateSource(
                        mode: mode, lease: lease, source: sourceFactory())
                    return ActivatedSystem(
                        dependency: dates as any DioramaDateSource,
                        deactivate: { dates.close() })
                }
            case .passthrough:
                return PreparedSystem {
                    let dates = LiveDateSource(
                        mode: .passthrough, lease: lease, source: sourceFactory())
                    return ActivatedSystem(
                        dependency: dates as any DioramaDateSource,
                        deactivate: { dates.close() })
                }
            case .replay:
                return PreparedSystem {
                    let dates = ReplayDateSource(lease: lease)
                    return ActivatedSystem(
                        dependency: dates as any DioramaDateSource,
                        deactivate: {})
                }
            }
        }
    }
}
