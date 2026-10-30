import DioramaCore
@testable import DioramaLocation
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LocationOriginPolicyTests {
    typealias Fixtures = LocationOriginFixtures

    @Test(arguments: [LocationCoordinateFormat.meters, .degrees])
    func `defaults replace origins after fresh offsets and latencies derive`(format: LocationCoordinateFormat) throws {
        let observed = try Fixtures.observed(format: format)
        let policy = LocationOriginPolicy(
            coordinate: Fixtures.defaultCoordinate,
            altitude: LocationAltitudeDefaults(meters: 40.12345, ellipsoidalMeters: 50.98765),
            timestamp: Fixtures.defaultTime)
        let prepared = try policy.prepare(observed)
        #expect(prepared.coordinateSpace?.origin == .observed(Fixtures.defaultCoordinate))
        #expect(prepared.altitudeOrigin?.meters == .observed(40.123))
        #expect(prepared.altitudeOrigin?.ellipsoidalMeters == .observed(50.988))
        #expect(prepared.initial?.timestampOrigin == Fixtures.defaultTime)
        #expect(prepared.sessions[0].timestampOrigin == .observed(Fixtures.defaultTime))
        #expect(prepared.sessions[0].events == observed.sessions[0].events)
        #expect(prepared.initial?.location == observed.initial?.location)
        #expect(prepared.access == observed.access)
        let point = try #require(prepared.initial?.location)
        let delivered = try prepared.measurement(
            for: point, timestampOrigin: Fixtures.defaultTime, deliveryMilliseconds: 250)
        let expectedCoordinate = try point.coordinateOffset.coordinate(relativeTo: Fixtures.defaultCoordinate)
        #expect(delivered.coordinate.latitude == expectedCoordinate.latitudeDegrees)
        #expect(delivered.coordinate.longitude == expectedCoordinate.longitudeDegrees)
        #expect(delivered.vertical?.orthometricAltitudeMeters == 42.456)
        #expect(delivered.vertical?.ellipsoidalAltitudeMeters == 54.433)
        #expect(delivered.timestamp == Fixtures.defaultTime.advanced(by: -1000))
        #expect(try LocationOriginPolicy().prepare(observed) == observed)
        #expect(try policy.prepare(prepared) == prepared)
    }

    @Test(arguments: [false, true], [false, true])
    func `authored origins win while altitude components remain independent`(meters: Bool, ellipsoidal: Bool) throws {
        let observed = try Fixtures.observed(format: .meters)
        let baseline = try Fixtures.authored(meters: meters, ellipsoidal: ellipsoidal)
        let fresh = try LocationOriginPolicy(
            coordinate: Fixtures.defaultCoordinate,
            altitude: LocationAltitudeDefaults(meters: 40, ellipsoidalMeters: 50),
            timestamp: Fixtures.defaultTime).prepare(observed)
        let merged = try Fixtures.merge(fresh, baseline: baseline)
        #expect(merged.coordinateSpace?.format == .meters)
        #expect(merged.coordinateSpace?.origin == .override(Fixtures.authoredCoordinate))
        #expect(merged.altitudeOrigin?.meters == (meters ? .override(10) : .observed(40)))
        #expect(merged.altitudeOrigin?.ellipsoidalMeters == (ellipsoidal ? .override(20) : .observed(50)))
        #expect(merged.sessions[0].timestampOrigin == .override(Fixtures.authoredTime))
        #expect(merged.sessions[0].events == fresh.sessions[0].events)
        #expect(merged.initial == fresh.initial)
        #expect(merged.access == fresh.access)
        #expect(observed.coordinateSpace?.origin == .observed(Fixtures.observedCoordinate))
        #expect(baseline.coordinateSpace?.origin == .override(Fixtures.authoredCoordinate))
    }

    @Test
    func `defaults are reevaluated and never become sticky overrides`() throws {
        let observed = try Fixtures.observed()
        let first = try LocationOriginPolicy(
            coordinate: Fixtures.defaultCoordinate,
            altitude: LocationAltitudeDefaults(meters: 40), timestamp: Fixtures.defaultTime).prepare(observed)
        let second = try LocationOriginPolicy(
            coordinate: Fixtures.authoredCoordinate,
            altitude: LocationAltitudeDefaults(ellipsoidalMeters: 70), timestamp: Fixtures.authoredTime)
            .prepare(observed)
        #expect(try Fixtures.merge(second, baseline: first) == second)
        #expect(try Fixtures.merge(observed, baseline: second) == observed)
        #expect(second.altitudeOrigin?.meters == observed.altitudeOrigin?.meters)
        #expect(second.altitudeOrigin?.ellipsoidalMeters == .observed(70))
        #expect(first.altitudeOrigin?.ellipsoidalMeters == observed.altitudeOrigin?.ellipsoidalMeters)
        #expect(LocationAltitudeDefaults(meters: .nan) == nil)
        #expect(LocationAltitudeDefaults(ellipsoidalMeters: .infinity) == nil)
    }

    @Test
    func `disappearing sessions and measurements drop obsolete origins without event correspondence`() throws {
        let baseline = try Fixtures.authored(sessionCount: 3)
        let observed = try Fixtures.observed()
        let emptySession = try LocationSession(timestampOrigin: nil, events: [
            .batch(delayMilliseconds: 5, locations: []),
        ])
        let fourth = observed.sessions[0]
        let fresh = try LocationRecording(
            coordinateSpace: observed.coordinateSpace, altitudeOrigin: observed.altitudeOrigin,
            sessions: [emptySession, fourth, fourth, fourth], access: Fixtures.access())
        let merged = try Fixtures.merge(fresh, baseline: baseline)
        #expect(merged.sessions.map(\.timestampOrigin) == [
            nil, .override(Fixtures.authoredTime), .override(Fixtures.authoredTime), fourth.timestampOrigin,
        ])
        #expect(merged.sessions.map(\.events) == fresh.sessions.map(\.events))
        let shrunk = try LocationRecording(
            coordinateSpace: observed.coordinateSpace, altitudeOrigin: observed.altitudeOrigin,
            initial: observed.initial, sessions: [], access: Fixtures.access())
        let initialOnly = try Fixtures.merge(shrunk, baseline: baseline)
        #expect(initialOnly.sessions.isEmpty)
        #expect(initialOnly.initial == shrunk.initial)
        #expect(initialOnly.coordinateSpace?.origin == baseline.coordinateSpace?.origin)
        let empty = try LocationRecording(coordinateSpace: nil, sessions: [emptySession], access: Fixtures.access())
        #expect(try Fixtures.merge(empty, baseline: baseline) == empty)
        let accessOnly = try LocationRecording(coordinateSpace: nil, sessions: [], access: Fixtures.access())
        #expect(try Fixtures.merge(accessOnly, baseline: baseline) == accessOnly)
    }

    @Test
    func `losing altitude drops both overrides while retaining horizontal locations`() throws {
        let point = try #require(LocationRecordedLocation(
            latencyMilliseconds: -7, coordinateOffset: .degrees(latitudeDegrees: 0.1, longitudeDegrees: 0.2),
            horizontalAccuracyMeters: 9))
        let session = try LocationSession(timestampOrigin: .observed(Fixtures.observedTime), events: [
            .batch(delayMilliseconds: 10, locations: [point]),
        ])
        let fresh = try LocationRecording(
            coordinateSpace: .init(format: .degrees, origin: .observed(Fixtures.observedCoordinate)),
            sessions: [session], access: Fixtures.access())
        let merged = try Fixtures.merge(fresh, baseline: Fixtures.authored())
        #expect(merged.altitudeOrigin == nil)
        #expect(merged.sessions[0].events == session.events)
        #expect(merged.sessions[0].timestampOrigin == .override(Fixtures.authoredTime))
    }

    @Test
    func `non origin edits are replaced wholesale`() throws {
        let observed = try Fixtures.observed()
        let editedPoint = try #require(LocationRecordedLocation(
            latencyMilliseconds: -500, coordinateOffset: .degrees(latitudeDegrees: 5, longitudeDegrees: 6),
            horizontalAccuracyMeters: 999, floor: .init(level: 99)))
        let editedSession = try LocationSession(timestampOrigin: .observed(Fixtures.authoredTime), events: [
            .batch(delayMilliseconds: 8000, locations: [editedPoint, editedPoint]),
        ])
        let baseline = try LocationRecording(
            coordinateSpace: observed.coordinateSpace,
            initial: .init(timestampOrigin: Fixtures.authoredTime, location: editedPoint),
            sessions: [editedSession, editedSession], access: Fixtures.access(.denied))
        #expect(try Fixtures.merge(observed, baseline: baseline) == observed)
    }

    @Test
    func `invalid default retiming rejects prepared output before admission`() throws {
        let earliest = try #require(TimestampOrigin(
            date: Date(timeIntervalSince1970: -62_135_500_000), offsetMinutes: 0))
        let observed = try Fixtures.observed()
        let policy = LocationOriginPolicy(timestamp: earliest)
        #expect(throws: LocationRecordingError.invalidMeasurement(position: 0)) {
            try policy.prepare(observed)
        }
        let sessionOnly = try LocationRecording(
            coordinateSpace: observed.coordinateSpace, altitudeOrigin: observed.altitudeOrigin,
            sessions: observed.sessions, access: observed.access)
        #expect(throws: LocationRecordingError.invalidMeasurement(position: 0)) {
            try policy.prepare(sessionOnly)
        }
        let accessOnly = try LocationRecording(coordinateSpace: nil, sessions: [], access: Fixtures.access())
        #expect(try policy.prepare(accessOnly) == accessOnly)
    }
}
