import DioramaCore

/// Independently selected setup defaults, normalized before capture uses them.
struct LocationAltitudeDefaults: Equatable, Sendable {
    let meters: Double?
    let ellipsoidalMeters: Double?

    init?(meters: Double? = nil, ellipsoidalMeters: Double? = nil) {
        guard meters?.isFinite != false, ellipsoidalMeters?.isFinite != false else { return nil }
        self.meters = meters.map(LocationPrecision.millimeters)
        self.ellipsoidalMeters = ellipsoidalMeters.map(LocationPrecision.millimeters)
    }
}

/// Capture policy contains setup defaults only; it never reads a loaded baseline.
/// Derive offsets and signed latencies against fresh normalized observed origins
/// first, then prepare the effective origins before admission or consumer delivery.
struct LocationOriginPolicy: Sendable {
    let coordinate: LocationCoordinate?
    let altitude: LocationAltitudeDefaults?
    let timestamp: TimestampOrigin?

    init(
        coordinate: LocationCoordinate? = nil,
        altitude: LocationAltitudeDefaults? = nil,
        timestamp: TimestampOrigin? = nil)
    {
        self.coordinate = coordinate
        self.altitude = altitude
        self.timestamp = timestamp
    }

    func coordinateSpace(observed: LocationCoordinateSpace) -> LocationCoordinateSpace {
        .init(format: observed.format, origin: .observed(coordinate ?? observed.origin.value))
    }

    func altitudeOrigin(observed: LocationAltitudeOrigin) -> LocationAltitudeOrigin {
        // Defaults and the observed origin have already passed finite-value validation.
        LocationAltitudeOrigin(
            meters: .observed(altitude?.meters ?? observed.meters.value),
            ellipsoidalMeters: .observed(altitude?.ellipsoidalMeters ?? observed.ellipsoidalMeters.value))!
    }

    func timestampOrigin(observed: TimestampOrigin) -> TimestampOrigin {
        timestamp ?? observed
    }

    /// Prepares a complete capture-local recording without retaining replaced origins.
    /// Incremental adapters use the same selectors before admitting headers/records.
    func prepare(_ observed: LocationRecording) throws(LocationRecordingError) -> LocationRecording {
        let initial = try observed.initial.map { initial throws(LocationRecordingError) in
            try LocationInitialSnapshot(
                timestampOrigin: timestampOrigin(observed: initial.timestampOrigin), location: initial.location)
        }
        let sessions = try observed.sessions.map { session throws(LocationRecordingError) in
            try LocationSession(
                timestampOrigin: session.timestampOrigin.map { .observed(timestampOrigin(observed: $0.value)) },
                events: session.events)
        }
        return try LocationRecording(
            coordinateSpace: observed.coordinateSpace.map(coordinateSpace),
            altitudeOrigin: observed.altitudeOrigin.map(altitudeOrigin),
            initial: initial, sessions: sessions, access: observed.access)
    }
}
