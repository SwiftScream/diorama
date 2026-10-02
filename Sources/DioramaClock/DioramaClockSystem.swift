import DioramaCore
import Foundation

/// Identity and persistence capability for first-party clock attachments.
///
/// Source capture and replay services arrive in later clock units.
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
}
