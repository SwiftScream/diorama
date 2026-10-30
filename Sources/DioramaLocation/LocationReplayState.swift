import DioramaCore

/// Both replay timelines belong to one attachment and one Core lifetime.
struct LocationReplayState: Sendable {
    let sessions: SequentialTrackLease<LocationSession, LocationTracks.SessionHeader>
    let access: SequentialTrackLease<LocationTracks.AccessSegment, LocationRecordedAccessState>
}
