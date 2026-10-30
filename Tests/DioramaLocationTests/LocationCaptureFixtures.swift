@testable import DioramaCore
@testable import DioramaLocation
import Foundation
import Synchronization
import Testing

final class LocationCaptureClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    var source: ExecutionClock {
        ExecutionClock(now: { self.instant.withLock { $0 } }, sleep: ExecutionClock.continuous().sleep)
    }

    func advance(_ duration: Duration) {
        instant.withLock { $0 = $0.advanced(by: duration) }
    }
}

private enum LocationFixtureError: Error { case unsupported }

private struct LocationCaptureDefinition: SystemDefinition {
    let systemType = LocationTracks.type
    let sessions: TrackDefinition<LocationSession, LocationTracks.SessionHeader>
    let access: TrackDefinition<LocationTracks.AccessSegment, LocationRecordedAccessState>

    init(hasLocations: Bool) throws {
        let origin = try #require(LocationCoordinate(latitudeDegrees: 0, longitudeDegrees: 0))
        let header = LocationTracks.SessionHeader(
            coordinateSpace: hasLocations ? LocationHorizontalSpace(
                format: .degrees, origin: .observed(origin)) : nil,
            altitudeOrigin: nil, initial: nil)
        sessions = try TrackDefinition("sessions", header: ValuePreparation().admitPrepared(header))
        access = try TrackDefinition(
            "access", header: ValuePreparation().admitPrepared(LocationCaptureFixtures.initial))
    }

    var tracks: [AnyTrackDefinition] {
        [sessions.erased, access.erased]
    }

    var record: SystemModeDefinition<LocationCaptureState, SystemExecution<LocationCaptureState>> {
        .init(makeState: makeState, makeDependency: { $0 })
    }

    var replay: SystemModeDefinition<LocationCaptureState, SystemExecution<LocationCaptureState>> {
        record
    }

    var passthrough: SystemModeDefinition<Void, SystemExecution<LocationCaptureState>> {
        .init(makeDependency: { _ in throw LocationFixtureError.unsupported })
    }

    func makeState(in context: borrowing SystemStateContext) throws -> LocationCaptureState {
        try LocationCaptureState(sessions: context.lease(for: sessions), access: context.lease(for: access))
    }
}

struct LocationCaptureFixtures {
    let execution: ScenarioExecution
    let capture: SystemExecution<LocationCaptureState>
    let clock: LocationCaptureClock

    static let timestampOrigin = TimestampOrigin(
        date: Date(timeIntervalSince1970: 1_893_456_000), offsetMinutes: 0)!
    static let initial = LocationRecordedAccessState(
        servicesEnabled: true, permission: .notDetermined, accuracy: .full)
    static let allowed = LocationRecordedAccessState(
        servicesEnabled: true, permission: .whenInUse, accuracy: .reduced)

    static func start(hasLocations: Bool = true, observing: Bool = true) async throws -> Self {
        let system = try ScenarioSystem(named: "gps", definition: LocationCaptureDefinition(hasLocations: hasLocations))
        let clock = LocationCaptureClock()
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]),
            scenarioID: ScenarioID(rawValue: "location-capture"), defaultMode: .record,
            systems: [AnyScenarioSystem(system)], clock: clock.source)
        let capture = try execution.dependency(system)
        if observing {
            try capture.state.withLock { state, operation in try state.beginAccess(operation: &operation) }
        }
        return Self(execution: execution, capture: capture, clock: clock)
    }

    func recording(_ result: ScenarioFinalizationResult) throws -> LocationRecording {
        let definition = try #require(result.definition)
        return try LocationTracks.recording(in: #require(definition.attachments.first))
    }

    func sessionObservation() throws -> LocationSessionObservation {
        try capture.state.withLock { state, operation in
            let token = try state.reserveSessionEvent(operation: &operation)
            return try #require(token)
        }
    }

    func accessObservation() throws -> LocationAccessObservation {
        try capture.state.withLock { state, operation in
            let token = try state.reserveAccessNotification(operation: &operation)
            return try #require(token)
        }
    }

    func complete(_ token: LocationSessionObservation, _ event: LocationCaptureEvent) throws -> Bool {
        let prepared = try ValuePreparation<LocationCaptureEvent>().admitPrepared(event)
        return try capture.state.withLock { state, operation in
            state.complete(token, with: prepared, operation: &operation)
        }
    }

    func complete(_ token: LocationAccessObservation, _ value: LocationRecordedAccessState) throws -> Bool {
        let prepared = try ValuePreparation<LocationRecordedAccessState>().admitPrepared(value)
        return try capture.state.withLock { state, operation in
            state.complete(token, with: prepared, operation: &operation)
        }
    }

    func location(
        _ milliseconds: Int64, at observation: LocationSessionObservation, east: Double = 0) throws
        -> LocationRecordedLocation
    {
        let timestamp = try #require(Self.timestampOrigin.advanced(by: milliseconds))
        let latency = try #require(observation.latency(for: timestamp))
        return try #require(LocationRecordedLocation(
            latencyMilliseconds: latency,
            coordinateOffset: .degrees(latitudeDegrees: 0, longitudeDegrees: east), horizontalAccuracyMeters: 1))
    }
}
