import DioramaCore
@testable import DioramaLocation
import DioramaPersistence
import Foundation
import Testing

enum LocationOriginFixtures {
    static let observedTime = TimestampOrigin("2037-04-05T06:07:08.000Z")!
    static let defaultTime = TimestampOrigin("2020-01-01T00:00:00.000+02:00")!
    static let authoredTime = TimestampOrigin("2010-06-01T00:00:00.000-03:00")!
    static let observedCoordinate = LocationCoordinate(latitudeDegrees: 37.12345678, longitudeDegrees: -122.98765432)!
    static let defaultCoordinate = LocationCoordinate(latitudeDegrees: -20, longitudeDegrees: 130)!
    static let authoredCoordinate = LocationCoordinate(latitudeDegrees: 50, longitudeDegrees: 10)!

    static func codec() throws -> JSONScenarioCodec {
        try JSONScenarioCodec(registry: PersistentSystemRegistry([LocationTracks.type]))
    }

    static func definition(_ recording: LocationRecording, named name: String = "gps") throws -> ScenarioDefinition {
        try ScenarioDefinition(attachments: [LocationTracks.attachment(named: name, recording: recording)])
    }

    static func content(_ definition: ScenarioDefinition, named name: String = "gps") throws -> LocationRecording {
        try LocationTracks.recording(in: #require(definition.attachment(for: AttachmentKey(rawValue: name))))
    }

    static func access(_ permission: LocationPermission = .notDetermined) throws -> LocationAccessRecording {
        try LocationAccessRecording(
            initialState: .init(servicesEnabled: true, permission: permission, accuracy: .full),
            initialNotifications: [
                .init(delayMilliseconds: 7, state: .init(
                    servicesEnabled: false, permission: permission, accuracy: .reduced)),
            ],
            requests: [.init(request: .always, notifications: [])])
    }

    /// Offsets derive from fresh observed origins before any policy substitution.
    static func observed(format: LocationCoordinateFormat = .degrees) throws -> LocationRecording {
        let coordinate = try #require(LocationCoordinate(latitudeDegrees: 37.12445678, longitudeDegrees: -122.98565432))
        let altitude = try #require(LocationAltitudeOrigin(
            meters: .observed(123.456), ellipsoidalMeters: .observed(145.678)))
        let point = try #require(LocationRecordedLocation(
            latencyMilliseconds: 1250,
            coordinateOffset: LocationCoordinateOffset.encode(
                coordinate, relativeTo: observedCoordinate, format: format),
            horizontalAccuracyMeters: 3.12345,
            altitudeOffset: LocationAltitudeOffset(
                meters: 125.789 - altitude.meters.value,
                ellipsoidalMeters: 149.123 - altitude.ellipsoidalMeters.value, accuracyMeters: 0.9),
            floor: .init(level: 3),
            speed: LocationSpeedEstimate(metersPerSecond: 4.321, accuracyMetersPerSecond: 0.2)))
        let session = try LocationSession(timestampOrigin: .observed(observedTime), events: [
            .batch(delayMilliseconds: 250, locations: [point]),
            .failure(delayMilliseconds: 12, error: #require(NSErrorSnapshot(domain: "safe.location", code: 1))),
            .batch(delayMilliseconds: 3, locations: []),
        ])
        return try LocationRecording(
            coordinateSpace: .init(format: format, origin: .observed(observedCoordinate)), altitudeOrigin: altitude,
            initial: .init(timestampOrigin: observedTime, location: point), sessions: [session], access: access())
    }

    static func authored(
        meters: Bool = true, ellipsoidal: Bool = true, sessionCount: Int = 1) throws -> LocationRecording
    {
        let fresh = try observed()
        let altitude = try #require(LocationAltitudeOrigin(
            meters: meters ? .override(10) : .observed(1000),
            ellipsoidalMeters: ellipsoidal ? .override(20) : .observed(2000)))
        let session = try LocationSession(timestampOrigin: .override(authoredTime), events: fresh.sessions[0].events)
        return try LocationRecording(
            coordinateSpace: .init(format: .degrees, origin: .override(authoredCoordinate)), altitudeOrigin: altitude,
            initial: fresh.initial, sessions: Array(repeating: session, count: sessionCount), access: access(.denied))
    }

    static func merge(_ fresh: LocationRecording, baseline: LocationRecording) throws -> LocationRecording {
        let old = try LocationTracks.attachment(named: "gps", recording: baseline)
        let new = try LocationTracks.attachment(named: "gps", recording: fresh)
        let id = new.trackIDs[0]
        let oldTrack = try old.track(id, as: LocationSession.self, header: LocationTracks.SessionHeader.self)
        let newTrack = try new.track(id, as: LocationSession.self, header: LocationTracks.SessionHeader.self)
        let merged = try LocationTracks.mergeSessions(
            baseline: #require(oldTrack), recording: #require(newTrack))
        return try LocationRecording(
            coordinateSpace: merged.header.coordinateSpace, altitudeOrigin: merged.header.altitudeOrigin,
            initial: merged.header.initial, sessions: merged.records.map(\.value), access: fresh.access)
    }
}

struct LocationMergeState: Sendable {
    let sessions: SequentialTrackLease<LocationSession, LocationTracks.SessionHeader>
    let access: SequentialTrackLease<LocationTracks.AccessSegment, LocationRecordedAccessState>

    /// Uses the real Core admission/finalization path, with no native manager.
    func record(_ fresh: LocationRecording, operation: inout SystemOperation<Self>) throws {
        let header = LocationTracks.SessionHeader(
            coordinateSpace: fresh.coordinateSpace, altitudeOrigin: fresh.altitudeOrigin, initial: fresh.initial)
        try operation.setHeader(on: sessions, capturing: { header }, preparation: ValuePreparation())
        for session in fresh.sessions {
            try operation.record(on: sessions, capturing: { session }, preparation: ValuePreparation())
        }
        try operation.setHeader(on: access, capturing: { fresh.access.initialState }, preparation: ValuePreparation())
        let segments = [LocationTracks.AccessSegment.initial(fresh.access.initialNotifications)]
            + fresh.access.requests.map(LocationTracks.AccessSegment.request)
        for segment in segments {
            try operation.record(on: access, capturing: { segment }, preparation: ValuePreparation())
        }
    }
}

struct LocationMergeDefinition: SystemDefinition {
    let systemType = LocationTracks.type
    let sessions: TrackDefinition<LocationSession, LocationTracks.SessionHeader>
    let access: TrackDefinition<LocationTracks.AccessSegment, LocationRecordedAccessState>

    init() throws {
        sessions = try LocationTracks.sessionDefinition(header: .init(
            coordinateSpace: nil, altitudeOrigin: nil, initial: nil))
        access = try TrackDefinition("access", header: ValuePreparation().admitPrepared(
            LocationOriginFixtures.access().initialState))
    }

    var tracks: [AnyTrackDefinition] {
        [sessions.erased, access.erased]
    }

    var record: SystemModeDefinition<LocationMergeState, SystemExecution<LocationMergeState>> {
        .init(makeState: makeState, makeDependency: { $0 })
    }

    var replay: SystemModeDefinition<LocationMergeState, SystemExecution<LocationMergeState>> {
        record
    }

    var passthrough: SystemModeDefinition<Void, SystemExecution<LocationMergeState>> {
        .init(makeDependency: { _ in throw LocationRecordingError.invalidTrackLayout })
    }

    func makeState(in context: borrowing SystemStateContext) throws -> LocationMergeState {
        try LocationMergeState(sessions: context.lease(for: sessions), access: context.lease(for: access))
    }
}
