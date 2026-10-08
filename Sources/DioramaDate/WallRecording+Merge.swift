import DioramaCore
import Foundation

extension WallRecording {
    /// Merges positional authorship into fresh deltas before rebuilding dates.
    /// Empty replacement deliberately discards every obsolete override.
    func preservingOverrides(from baseline: WallRecording) throws(WallRecordingError) -> WallRecording {
        guard !observations.isEmpty else { return .empty }
        let mergedOrigin: OverridableValue<WallOrigin>? = if let authored = baseline.origin, authored.isOverride {
            authored
        } else {
            origin
        }
        let merged = observations.enumerated().map { position, fresh in
            if position > 0, position < baseline.observations.count, baseline.observations[position].isOverride {
                baseline.observations[position]
            } else {
                fresh
            }
        }
        return try WallRecording(origin: mergedOrigin, observations: merged)
    }
}

extension DioramaDateSystem {
    /// Reconstructs both strict wall sequences and validates the merged result.
    static func mergeWallRecording(
        baseline: SequentialTrack<OverridableValue<Date>, Int?>,
        recording: SequentialTrack<OverridableValue<Date>, Int?>)
        throws -> SequentialTrack<OverridableValue<Date>, Int?>
    {
        let original = try WallRecording(offsetMinutes: baseline.header, values: baseline.records.map(\.value))
        let fresh = try WallRecording(offsetMinutes: recording.header, values: recording.records.map(\.value))
        return try track(id: recording.id, recording: fresh.preservingOverrides(from: original))
    }
}
