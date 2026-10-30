import DioramaCore

extension LocationTracks {
    /// The same definition serves initial recording and re-recording. Access uses
    /// ordinary whole-track replacement and has no merge-preserving fields.
    static func sessionDefinition(header: SessionHeader) throws -> TrackDefinition<LocationSession, SessionHeader> {
        try TrackDefinition(
            "sessions", header: ValuePreparation().admitPrepared(header), mergeRecording: mergeSessions)
    }

    /// Retains only permitted origins, after every fresh record has frozen.
    /// Fresh setup defaults are ordinary observations; baseline observations never win.
    static func mergeSessions(
        baseline: SequentialTrack<LocationSession, SessionHeader>,
        recording: SequentialTrack<LocationSession, SessionHeader>) throws
        -> SequentialTrack<LocationSession, SessionHeader>
    {
        let fresh = recording.header
        let original = baseline.header
        let coordinateSpace = fresh.coordinateSpace.map { space in
            LocationCoordinateSpace(
                format: space.format, origin: preservingOverride(space.origin, from: original.coordinateSpace?.origin))
        }
        let altitudeOrigin = fresh.altitudeOrigin.map { altitude in
            LocationAltitudeOrigin(
                meters: preservingOverride(altitude.meters, from: original.altitudeOrigin?.meters),
                ellipsoidalMeters: preservingOverride(
                    altitude.ellipsoidalMeters, from: original.altitudeOrigin?.ellipsoidalMeters))!
        }
        let sessions = try recording.records.enumerated().map { index, record in
            let previous = baseline.records.indices.contains(index)
                ? baseline.records[index].value.timestampOrigin : nil
            return try LocationSession(
                timestampOrigin: record.value.timestampOrigin.map { preservingOverride($0, from: previous) },
                events: record.value.events)
        }
        try LocationRecording.validateLocations(
            coordinateSpace: coordinateSpace, altitudeOrigin: altitudeOrigin,
            initial: fresh.initial, sessions: sessions)
        let header = SessionHeader(
            coordinateSpace: coordinateSpace, altitudeOrigin: altitudeOrigin, initial: fresh.initial)
        return try SequentialTrack(
            id: recording.id, header: ValuePreparation().admitPrepared(header),
            values: sessions.map { try ValuePreparation().admitPrepared($0) })
    }

    private static func preservingOverride<Value>(
        _ fresh: OverridableValue<Value>, from baseline: OverridableValue<Value>?) -> OverridableValue<Value>
    {
        if let baseline, baseline.isOverride {
            baseline
        } else {
            fresh
        }
    }
}
