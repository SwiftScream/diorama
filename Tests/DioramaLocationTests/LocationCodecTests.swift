import CoreLocation
import DioramaCore
@testable import DioramaLocation
import DioramaPersistence
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LocationCodecTests {
    private func codec() throws -> JSONScenarioCodec {
        try JSONScenarioCodec(registry: PersistentSystemRegistry([LocationTracks.type]))
    }

    private func encoded(_ recording: LocationRecording) throws -> Data {
        try codec().encode(ScenarioDefinition(attachments: [
            LocationTracks.attachment(named: "gps", recording: recording),
        ]))
    }

    private func decoded(_ bytes: Data) throws -> LocationRecording {
        let definition = try codec().decode(bytes)
        return try LocationTracks.recording(in: #require(definition.attachments.first))
    }

    private func fixture(_ name: String) throws -> Data {
        let path = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: path)
    }

    private func utf8(_ bytes: Data) throws -> String {
        try #require(String(data: bytes, encoding: .utf8))
    }

    func downstreamRequest(_ value: LocationMeasurement) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode([
            "latitude": value.coordinate.latitude,
            "longitude": value.coordinate.longitude,
            "altitude": value.vertical?.orthometricAltitudeMeters,
            "accuracy": value.horizontalAccuracyMeters,
            "speed": value.speed?.metersPerSecond,
            "timestamp": value.timestamp.timeIntervalSince1970,
        ])
    }

    @Test
    func `meter golden preserves native scalars and latency timestamps`() throws {
        let recording = try LocationSamples.meters()
        let bytes = try encoded(recording)
        let expected = try fixture("meters")
        #expect(bytes == expected)
        let read = try decoded(bytes)
        #expect(read == recording)
        let space = try #require(read.horizontal)
        let session = try #require(read.sessions.first)
        #expect(session.timestampOrigin?.value.text == "2030-01-01T00:00:00.000Z")
        guard case let .batch(firstDelay, firstLocations) = session.events[0],
              case let .failure(failureDelay, _) = session.events[1],
              case let .batch(lastDelay, lastLocations) = session.events[2]
        else { Issue.record("Wrong session event order"); return }
        #expect(firstDelay == 50)
        #expect(failureDelay == 5000)
        #expect(lastDelay == 2)
        #expect(firstLocations[0].latencyMilliseconds == 50)
        #expect(lastLocations[0].latencyMilliseconds == 10052)
        #expect(firstLocations[0].altitudeOffset?.meters == 2)
        #expect(firstLocations[0].altitudeOffset?.ellipsoidalMeters == 3)
        let coordinate = try space.coordinate(for: lastLocations[0].coordinateOffset)
        #expect(abs(coordinate.latitudeDegrees - -35.2809) < 0.0000001)
        #expect(abs(coordinate.longitudeDegrees - 149.13) < 0.0000001)
        let measurementTime = try #require(session.timestampOrigin?.value.advanced(by: -5000))
        let measurement = try read.measurement(
            for: lastLocations[0], timestampOrigin: #require(session.timestampOrigin?.value),
            deliveryMilliseconds: 5052)
        #expect(measurement.vertical?.orthometricAltitudeMeters == 112)
        #expect(measurement.vertical?.ellipsoidalAltitudeMeters == 123)
        #expect(measurement.timestamp == measurementTime)
        let initial = try #require(read.initial)
        #expect(initial.timestampOrigin.text == "2030-01-01T00:00:00.000Z")
        #expect(initial.location.timestamp(relativeTo: initial.timestampOrigin, deliveryMilliseconds: 0)
            == initial.timestampOrigin.advanced(by: -1000))
        #expect(read.access.initialNotifications[0].state.permission == .whenInUse)
        #expect(read.access.requests[0].request == .always)
        let attachment = try LocationTracks.attachment(named: "gps", recording: read)
        #expect(attachment.trackIDs.map(\.key.rawValue) == ["sessions", "access"])
        #expect(try codec().encode(ScenarioDefinition(attachments: [attachment])) == bytes)
    }

    @Test
    func `degree golden reflects poles and keeps explicit format`() throws {
        let recording = try LocationSamples.degrees()
        let bytes = try encoded(recording)
        let expected = try fixture("degrees")
        #expect(bytes == expected)
        let read = try decoded(bytes)
        let space = try #require(read.horizontal)
        #expect(space.format == .degrees)
        let initial = try #require(read.initial)
        let reflected = try space.coordinate(for: initial.location.coordinateOffset)
        #expect(reflected.latitudeDegrees == 80)
        #expect(reflected.longitudeDegrees == -160)
        #expect(try encoded(read) == bytes)
    }

    @Test
    func `access only has no coordinate origin and preserves a known when in use status on macOS`() throws {
        let recording = try LocationSamples.accessOnly()
        let bytes = try encoded(recording)
        let expected = try fixture("access-only")
        #expect(bytes == expected)
        let read = try decoded(bytes)
        #expect(read.horizontal == nil)
        #expect(read.access.initialNotifications[0].state.permission == .whenInUse)
        let native = try LocationAccessState(
            servicesEnabled: true,
            permission: #require(CLAuthorizationStatus(rawValue: 4)),
            accuracy: .fullAccuracy)
        #expect(try LocationRecordedAccessState(native).permission == .whenInUse)
        let unsupported = try LocationAccessState(
            servicesEnabled: true,
            permission: #require(CLAuthorizationStatus(rawValue: 99)),
            accuracy: .fullAccuracy)
        #expect(throws: LocationRecordingError.unsupportedAuthorization) {
            try LocationRecordedAccessState(unsupported)
        }
        let unsupportedAccuracy = try LocationAccessState(
            servicesEnabled: true,
            permission: .authorizedAlways,
            accuracy: #require(CLAccuracyAuthorization(rawValue: 99)))
        #expect(throws: LocationRecordingError.unsupportedAuthorization) {
            try LocationRecordedAccessState(unsupportedAccuracy)
        }
    }

    @Test
    func `relocated regional artifact needs only replacement origin and retained offsets`() throws {
        let original = try LocationSamples.meters()
        let before = try encoded(original)
        let origin = try #require(LocationCoordinate(latitudeDegrees: 10, longitudeDegrees: 20))
        let relocated = try original.relocated(to: origin)
        let after = try encoded(relocated)
        let read = try decoded(after)
        #expect(read.horizontal?.origin == .override(origin))
        #expect(read.sessions == original.sessions)
        #expect(read.initial == original.initial)
        let relocatedText = try utf8(after)
        #expect(!relocatedText.contains("151.2093"))
        #expect(before != after)
        let offset = try #require(read.initial?.location.coordinateOffset)
        #expect(try read.horizontal?.coordinate(for: offset) == origin)
    }

    @Test
    func `global relocation retains offsets through a reflected pole`() throws {
        let original = try LocationSamples.degrees()
        let replacement = try #require(LocationCoordinate(latitudeDegrees: -80, longitudeDegrees: 179.9))
        let relocated = try original.relocated(to: replacement)
        let read = try decoded(encoded(relocated))
        #expect(read.initial?.location.coordinateOffset == original.initial?.location.coordinateOffset)
        let offset = try #require(read.initial?.location.coordinateOffset)
        let space = try #require(read.horizontal)
        let coordinate = try space.coordinate(for: offset)
        #expect(coordinate.latitudeDegrees == -60)
        #expect(coordinate.longitudeDegrees == 179.9)
        let relocatedText = try utf8(encoded(relocated))
        #expect(!relocatedText.contains("\"latitudeDegrees\" : 80"))
    }

    @Test
    func `schema rejects unknown fields malformed values and unsupported version`() throws {
        let baseline = try utf8(encoded(LocationSamples.meters()))
        let variants = [
            baseline.replacingOccurrences(of: "\"coordinateFormat\" : \"meters\"",
                                          with: "\"coordinateFormat\" : \"mystery\""),
            baseline.replacingOccurrences(of: "\"coordinateFormat\" : \"meters\"",
                                          with: "\"coordinateFormat\" : \"meters\", \"mystery\" : 1"),
            baseline.replacingOccurrences(of: "\"delay\" : \"50ms\"", with: "\"delay\" : \"-1ms\""),
            baseline.replacingOccurrences(of: "\"permission\" : \"whenInUse\"",
                                          with: "\"permission\" : \"futureStatus\""),
            baseline.replacingOccurrences(of: "\"conclusion\" : \"openAtRecordingHorizon\"",
                                          with: "\"conclusion\" : \"finished\""),
            baseline.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2"),
            baseline.replacingOccurrences(of: "\"level\" : 1", with: "\"level\" : null"),
            baseline.replacingOccurrences(of: "\"latency\" : \"50ms\"",
                                          with: "\"latency\" : \"invalid\""),
            baseline.replacingOccurrences(of: "\"eastMeters\" : -189170.219",
                                          with: "\"eastMeters\" : 2500000.01"),
            baseline.replacingOccurrences(of: "\"domain\" : \"kCLErrorDomain\"",
                                          with: "\"domain\" : \"\""),
            baseline.replacingOccurrences(of: "\"sourceInformation\" : {",
                                          with: "\"sourceInformation\" : { \"unknown\" : true,"),
        ]
        for variant in variants {
            #expect(variant != baseline)
            #expect(throws: (any Error).self) { try decoded(Data(variant.utf8)) }
        }
    }

    @Test
    func `strict model rejects mixed offsets and absent vertical origins`() throws {
        let regional = try LocationSamples.meters()
        let space = try #require(regional.horizontal)
        let global = try #require(LocationRecordedLocation(
            latencyMilliseconds: 0, coordinateOffset: .degrees(latitudeDegrees: 0, longitudeDegrees: 0),
            horizontalAccuracyMeters: 1))
        let initialOrigin = try #require(TimestampOrigin("2030-01-01T00:00:00.000Z"))
        let initial = try LocationInitialSnapshot(
            timestampOrigin: initialOrigin,
            location: global)
        #expect(throws: LocationRecordingError.mixedCoordinateFormats) {
            try LocationRecording(horizontal: space, initial: initial,
                                  sessions: [], access: regional.access)
        }
        #expect(throws: LocationRecordingError.missingVerticalOrigins) {
            try LocationRecording(horizontal: space, initial: regional.initial,
                                  sessions: regional.sessions, access: regional.access)
        }
        #expect(throws: LocationRecordingError.unusedCoordinateOrigin) {
            try LocationRecording(horizontal: space, sessions: [], access: regional.access)
        }
        let overflowingHeight = try #require(LocationRecordedLocation(
            latencyMilliseconds: 0, coordinateOffset: .meters(eastMeters: 0, northMeters: 0),
            horizontalAccuracyMeters: 0,
            altitudeOffset: LocationAltitudeOffset(
                meters: 1e308, ellipsoidalMeters: 1e308, accuracyMeters: 1)))
        #expect(throws: LocationRecordingError.invalidMeasurement(position: 0)) {
            try LocationRecording(
                horizontal: space,
                altitudeOrigin: LocationAltitudeOrigin(meters: .observed(1e308), ellipsoidalMeters: .observed(1e308)),
                initial: .init(timestampOrigin: initialOrigin, location: overflowingHeight),
                sessions: [], access: regional.access)
        }
    }

    @Test
    func `native coordinate scalars encode explicitly and normalize aliases`() throws {
        let native = CLLocationCoordinate2D(latitude: -0.0, longitude: 180)
        let stable = try #require(LocationCoordinate(native))
        let bytes = try JSONEncoder().encode(stable)
        let text = try utf8(bytes)
        #expect(text.contains("\"latitudeDegrees\":0"))
        #expect(text.contains("\"longitudeDegrees\":-180"))
        #expect(try JSONDecoder().decode(LocationCoordinate.self, from: bytes) == stable)
        #expect(LocationCoordinate(latitudeDegrees: 90.001, longitudeDegrees: 0) == nil)
    }

    @Test
    func `initial and batched locations share signed latency reconstruction`() throws {
        let native = Date(timeIntervalSince1970: 1_893_456_000.0006)
        let origin = try #require(TimestampOrigin(date: native, offsetMinutes: 0))
        #expect(origin.text == "2030-01-01T00:00:00.001Z")
        let old = try #require(LocationRecordedLocation(
            latencyMilliseconds: 5000, coordinateOffset: .meters(eastMeters: 0, northMeters: 0),
            horizontalAccuracyMeters: 1))
        let future = try #require(LocationRecordedLocation(
            latencyMilliseconds: -250, coordinateOffset: .meters(eastMeters: 0, northMeters: 0),
            horizontalAccuracyMeters: 1))
        let error = try #require(NSErrorSnapshot(domain: "location", code: 1, userInfo: [:]))
        let session = try LocationSession(timestampOrigin: .observed(origin), events: [
            .batch(delayMilliseconds: 1000, locations: []),
            .failure(delayMilliseconds: 50, error: error),
            .batch(delayMilliseconds: 2000, locations: [old, future]),
        ])
        let initial = try LocationInitialSnapshot(timestampOrigin: origin, location: old)
        #expect(initial.location.timestamp(relativeTo: origin, deliveryMilliseconds: 0) == origin.advanced(by: -5000))
        #expect(old.timestamp(relativeTo: origin, deliveryMilliseconds: 3050) == origin.advanced(by: -1950))
        #expect(future.timestamp(relativeTo: origin, deliveryMilliseconds: 3050) == origin.advanced(by: 3300))
        // Editing a delivery delay shifts timestamps without changing the retained location.
        #expect(old.timestamp(relativeTo: origin, deliveryMilliseconds: 4050) == origin.advanced(by: -950))
        #expect(try JSONDecoder().decode(LocationSession.self, from: JSONEncoder().encode(session)) == session)
        #expect(try JSONDecoder().decode(LocationInitialSnapshot.self, from: JSONEncoder().encode(initial)) == initial)
    }

    @Test
    func `latency subtraction date range and cumulative delivery overflow fail admission`() throws {
        let origin = try #require(TimestampOrigin("2030-01-01T00:00:00.000Z"))
        for latency in [Int64.min, Int64.max] {
            let location = try #require(LocationRecordedLocation(
                latencyMilliseconds: latency, coordinateOffset: .meters(eastMeters: 0, northMeters: 0),
                horizontalAccuracyMeters: 0))
            #expect(throws: LocationRecordingError.invalidMeasurement(position: 0)) {
                try LocationInitialSnapshot(timestampOrigin: origin, location: location)
            }
            #expect(throws: LocationRecordingError.invalidMeasurement(position: 0)) {
                try LocationSession(timestampOrigin: .observed(origin), events: [
                    .batch(delayMilliseconds: 1, locations: [location]),
                ])
            }
        }
        #expect(throws: LocationRecordingError.cumulativeOverflow(position: 1)) {
            try LocationSession(timestampOrigin: nil, events: [
                .batch(delayMilliseconds: .max, locations: []),
                .batch(delayMilliseconds: 1, locations: []),
            ])
        }
        #expect(throws: LocationRecordingError.invalidMeasurement(position: 0)) {
            try LocationSession(timestampOrigin: .observed(origin), events: [])
        }
    }

    @Test
    func `edited locations normalize precision and keep strict altitude pairs`() throws {
        let json = Data(#"""
        {
          "latency": "-1ms",
          "coordinateOffset": { "eastMeters": 1.2345, "northMeters": -0.0004 },
          "horizontalAccuracyMeters": 0.0004,
          "altitudeOffset": { "meters": -2.3455, "ellipsoidalMeters": 3.45678 },
          "verticalAccuracyMeters": 0.0004,
          "floor": { "level": -1 },
          "speed": { "metersPerSecond": 1.2345, "accuracyMetersPerSecond": 0.3455 },
          "course": { "degrees": 359.9996, "accuracyDegrees": 0.0004 },
          "sourceInformation": { "isSimulatedBySoftware": true, "isProducedByAccessory": false }
        }
        """#.utf8)
        let location = try JSONDecoder().decode(LocationRecordedLocation.self, from: json)
        #expect(location.coordinateOffset == .meters(eastMeters: 1.235, northMeters: 0))
        #expect(location.horizontalAccuracyMeters == 0)
        #expect(location.altitudeOffset?.meters == -2.346)
        #expect(location.altitudeOffset?.ellipsoidalMeters == 3.457)
        #expect(location.altitudeOffset?.accuracyMeters == 0.001)
        #expect(location.floor?.level == -1)
        #expect(location.speed?.metersPerSecond == 1.235)
        #expect(location.speed?.accuracyMetersPerSecond == 0.346)
        #expect(location.course?.degrees == 0)
        #expect(location.course?.accuracyDegrees == 0)
        let bytes = try JSONEncoder().encode(location)
        #expect(try JSONDecoder().decode(LocationRecordedLocation.self, from: bytes) == location)
        let text = try utf8(bytes)
        #expect(text.contains("\"eastMeters\":1.235"))
        #expect(!text.contains("-0"))
        let original = try utf8(json)
        for invalid in [
            original.replacingOccurrences(of: "\"verticalAccuracyMeters\": 0.0004,", with: ""),
            original.replacingOccurrences(of: "\"verticalAccuracyMeters\": 0.0004",
                                          with: "\"verticalAccuracyMeters\": 0"),
            original.replacingOccurrences(of: "\"altitudeOffset\"", with: "\"vertical\""),
            original.replacingOccurrences(of: "\"level\": -1", with: "\"level\": -1, \"unknown\": 1"),
        ] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(LocationRecordedLocation.self, from: Data(invalid.utf8))
            }
        }
    }

    @Test
    func `degree rounding canonicalizes aliases and preserves millimeter coordinate accuracy`() throws {
        let origin = try #require(LocationCoordinate(latitudeDegrees: -0.000000004, longitudeDegrees: 179.999999996))
        #expect(origin.latitudeDegrees == 0)
        #expect(origin.longitudeDegrees == -180)
        let location = try #require(LocationRecordedLocation(
            latencyMilliseconds: 0,
            coordinateOffset: .degrees(latitudeDegrees: 1.234567895, longitudeDegrees: 179.999999996),
            horizontalAccuracyMeters: 1))
        #expect(location.coordinateOffset == .degrees(latitudeDegrees: 1.23456790, longitudeDegrees: -180))
        let bytes = try JSONEncoder().encode(location)
        #expect(try JSONDecoder().decode(LocationRecordedLocation.self, from: bytes) == location)
        let nativeOrigin = LocationGeodesy.Coordinate(latitude: 37.774900004, longitude: -122.419400004)
        let nativePoint = LocationGeodesy.Coordinate(latitude: 34.052200004, longitude: -118.243700004)
        let normalizedOrigin = try #require(LocationCoordinate(
            latitudeDegrees: nativeOrigin.latitude, longitudeDegrees: nativeOrigin.longitude))
        let point = try #require(LocationCoordinate(
            latitudeDegrees: nativePoint.latitude, longitudeDegrees: nativePoint.longitude))
        for format in [LocationCoordinateFormat.meters, .degrees] {
            let offset = try LocationHorizontalOffset.encode(point, relativeTo: normalizedOrigin, format: format)
            let reconstructed = try offset.coordinate(relativeTo: normalizedOrigin)
            let error = try LocationGeodesy.forward(origin: nativePoint, point: reconstructed.geodesy).value.radius
            #expect(error < 0.01)
        }
    }

    @Test
    func `altitude origins normalize independently and preserve component overrides`() throws {
        let json = Data(#"{"meters":{"observed":100,"override":12.3455},"ellipsoidalMeters":-23.4565}"#.utf8)
        let origin = try JSONDecoder().decode(LocationAltitudeOrigin.self, from: json)
        #expect(origin.meters == .override(12.346))
        #expect(origin.ellipsoidalMeters == .observed(-23.457))
        let bytes = try JSONEncoder().encode(origin)
        #expect(try JSONDecoder().decode(LocationAltitudeOrigin.self, from: bytes) == origin)
        let text = try utf8(bytes)
        #expect(!text.contains("observed"))
        #expect(!text.contains("100"))
        #expect(LocationAltitudeOrigin(meters: .observed(.infinity), ellipsoidalMeters: .observed(1)) == nil)
    }

    @Test
    func `millimeter rounding rejects a newly excessive meter radius`() {
        let component = (LocationGeodesy.maximumRadius - 0.00001) / sqrt(2)
        #expect(hypot(component, component) < LocationGeodesy.maximumRadius)
        #expect(LocationRecordedLocation(
            latencyMilliseconds: 0, coordinateOffset: .meters(eastMeters: component, northMeters: component),
            horizontalAccuracyMeters: 0) == nil)
    }

    @Test
    func `fresh normalized consumer values survive persistence before authored relocation`() throws {
        let timeOrigin = try #require(TimestampOrigin("2030-01-01T00:00:00.000Z"))
        let raw = try #require(LocationMeasurement(
            coordinate: CLLocationCoordinate2D(latitude: 37.1234567891, longitude: -122.1234567891),
            horizontalAccuracyMeters: 3.12345,
            vertical: LocationVerticalEstimate(
                orthometricAltitudeMeters: 101.0019, ellipsoidalAltitudeMeters: 121.0019, accuracyMeters: 0.0004),
            speed: LocationSpeedEstimate(metersPerSecond: 1.2345, accuracyMetersPerSecond: 0.12345),
            course: LocationCourseEstimate(degrees: 12.3456, accuracyDegrees: 0.23456),
            timestamp: timeOrigin.date.addingTimeInterval(0.0004)))
        let coordinateOrigin = try #require(LocationCoordinate(raw.coordinate))
        let altitudeOrigin = try #require(LocationAltitudeOrigin(
            meters: .observed(100.0012), ellipsoidalMeters: .observed(120.0012)))
        let vertical = try #require(raw.vertical)
        let offset = try #require(LocationAltitudeOffset(
            meters: vertical.orthometricAltitudeMeters - altitudeOrigin.meters.value,
            ellipsoidalMeters: vertical.ellipsoidalAltitudeMeters - altitudeOrigin.ellipsoidalMeters.value,
            accuracyMeters: vertical.accuracyMeters))
        let location = try #require(LocationRecordedLocation(
            latencyMilliseconds: 10, coordinateOffset: .meters(eastMeters: 0, northMeters: 0),
            horizontalAccuracyMeters: raw.horizontalAccuracyMeters, altitudeOffset: offset,
            speed: raw.speed, course: raw.course))
        let session = try LocationSession(timestampOrigin: .observed(timeOrigin), events: [
            .batch(delayMilliseconds: 10, locations: [location]),
        ])
        let fresh = try LocationRecording(
            horizontal: .init(format: .meters, origin: .observed(coordinateOrigin)),
            altitudeOrigin: altitudeOrigin, sessions: [session], access: LocationSamples.access())
        let delivered = try fresh.measurement(for: location, timestampOrigin: timeOrigin, deliveryMilliseconds: 10)
        #expect(delivered.vertical?.orthometricAltitudeMeters == 101.002)
        #expect(delivered.vertical?.ellipsoidalAltitudeMeters == 121.002)
        #expect(delivered.vertical?.accuracyMeters == 0.001)
        #expect(delivered.timestamp == timeOrigin.date)

        let replay = try decoded(encoded(fresh))
        #expect(replay == fresh)
        let replayed = try replay.measurement(
            for: location, timestampOrigin: timeOrigin, deliveryMilliseconds: 10)
        #expect(replayed == delivered)
        #expect(try downstreamRequest(delivered) == downstreamRequest(replayed))
        #expect(try downstreamRequest(raw) != downstreamRequest(delivered))

        // Publication may retain an authored origin without replacing the fresh delivery.
        let authored = try #require(LocationCoordinate(latitudeDegrees: -20, longitudeDegrees: 130))
        let published = try decoded(encoded(fresh.relocated(to: authored)))
        let editedReplay = try published.measurement(
            for: location, timestampOrigin: timeOrigin, deliveryMilliseconds: 10)
        #expect(editedReplay.coordinate.latitude == -20)
        #expect(delivered.coordinate.latitude == coordinateOrigin.latitudeDegrees)
        #expect(try fresh.measurement(
            for: location, timestampOrigin: timeOrigin, deliveryMilliseconds: 10) == delivered)
    }

    @Test
    func `decimal output preserves canonical binary values without further rounding`() throws {
        for raw in [0.0004, 0.0005, 1.2345, 100.001, 1_000_000_000_000_000.125, 1e308] {
            let origin = try #require(LocationAltitudeOrigin(
                meters: .observed(raw), ellipsoidalMeters: .override(-raw)))
            let bytes = try JSONEncoder().encode(origin)
            #expect(try JSONDecoder().decode(LocationAltitudeOrigin.self, from: bytes) == origin)
        }
        let origin = try #require(LocationAltitudeOrigin(
            meters: .observed(1.2345), ellipsoidalMeters: .override(-100.001)))
        let text = try utf8(JSONEncoder().encode(origin))
        #expect(text.contains("\"meters\":1.235"))
        #expect(text.contains("\"override\":-100.001"))
        let coordinate = try #require(LocationCoordinate(
            latitudeDegrees: 12.345678905, longitudeDegrees: -100.123456789))
        let coordinateText = try utf8(JSONEncoder().encode(coordinate))
        #expect(coordinateText.contains("\"latitudeDegrees\":12.34567891"))
        #expect(coordinateText.contains("\"longitudeDegrees\":-100.12345679"))
        #expect(throws: (any Error).self) {
            // Encoding cannot silently quantize an unprepared value behind the consumer's back.
            try JSONEncoder().encode(LocationHorizontalOffset.meters(eastMeters: 1.2345, northMeters: 0))
        }
    }

    @Test
    func `regional solver agrees with independent published and G02 references`() throws {
        struct Reference {
            let origin: (Double, Double)
            let point: (Double, Double)
            let offset: (Double, Double)
        }
        let pairs: [Reference] = [
            .init(origin: (0, 0), point: (0, 1), offset: (111_319.49079327357, 0)),
            .init(origin: (0, 0), point: (1, 0), offset: (0, 110_574.38855779878)),
            .init(origin: (-33.8688, 151.2093), point: (-35.2809, 149.13),
                  offset: (-189_170.21922399243, -158_584.8200909673)),
            .init(origin: (37.7749, -122.4194), point: (34.0522, -118.2437),
                  offset: (385_687.5201443627, -404_689.35099439457)),
        ]
        for reference in pairs {
            let origin = try #require(LocationCoordinate(
                latitudeDegrees: reference.origin.0, longitudeDegrees: reference.origin.1))
            let point = try #require(LocationCoordinate(
                latitudeDegrees: reference.point.0, longitudeDegrees: reference.point.1))
            let offset = try LocationHorizontalOffset.encode(point, relativeTo: origin, format: .meters)
            guard case let .meters(actualEast, actualNorth) = offset else {
                Issue.record("Expected regional offset")
                return
            }
            #expect(abs(actualEast - reference.offset.0) < 0.01)
            #expect(abs(actualNorth - reference.offset.1) < 0.01)
            let roundTrip = try offset.coordinate(relativeTo: origin)
            #expect(abs(roundTrip.latitudeDegrees - reference.point.0) < 0.0000001)
            #expect(abs(roundTrip.longitudeDegrees - reference.point.1) < 0.0000001)
        }
        let pole = try #require(LocationCoordinate(latitudeDegrees: -90, longitudeDegrees: -179.999999))
        let polarPoint = try #require(LocationCoordinate(
            latitudeDegrees: -81.04623281595062, longitudeDegrees: -179.999999))
        let offset = try LocationHorizontalOffset.encode(polarPoint, relativeTo: pole, format: .meters)
        guard case let .meters(east, north) = offset else {
            Issue.record("Expected regional offset")
            return
        }
        #expect(abs(east) < 0.01)
        #expect(abs(north - 1_000_000) < 0.01)
        #expect(LocationRecordedLocation(
            latencyMilliseconds: 0, coordinateOffset: .meters(eastMeters: 2_500_000, northMeters: 0),
            horizontalAccuracyMeters: 0) != nil)
        #expect(LocationRecordedLocation(
            latencyMilliseconds: 0, coordinateOffset: .meters(eastMeters: 2_500_000.01, northMeters: 0),
            horizontalAccuracyMeters: 0) == nil)
    }
}

private enum LocationSamples {
    static func access() throws -> LocationAccessRecording {
        let initial = LocationRecordedAccessState(
            servicesEnabled: true, permission: .notDetermined, accuracy: .full)
        let whenInUse = LocationRecordedAccessState(
            servicesEnabled: true, permission: .whenInUse, accuracy: .reduced)
        let always = LocationRecordedAccessState(
            servicesEnabled: true, permission: .always, accuracy: .full)
        let request = LocationAccessRequestSegment(
            request: .always, notifications: [.init(delayMilliseconds: 20, state: always)])
        return try LocationAccessRecording(
            initialState: initial,
            initialNotifications: [.init(delayMilliseconds: 10, state: whenInUse)],
            requests: [request])
    }

    static func accessOnly() throws -> LocationRecording {
        try LocationRecording(horizontal: nil, sessions: [], access: access())
    }

    static func meters() throws -> LocationRecording {
        let origin = try #require(LocationCoordinate(latitudeDegrees: -33.8688, longitudeDegrees: 151.2093))
        let destination = try #require(LocationCoordinate(latitudeDegrees: -35.2809, longitudeDegrees: 149.13))
        let space = LocationHorizontalSpace(format: .meters, origin: .observed(origin))
        func atOrigin(latency: Int64) throws -> LocationRecordedLocation {
            try #require(LocationRecordedLocation(
                latencyMilliseconds: latency,
                coordinateOffset: .meters(eastMeters: 0, northMeters: 0),
                horizontalAccuracyMeters: 3,
                altitudeOffset: LocationAltitudeOffset(meters: 2, ellipsoidalMeters: 3, accuracyMeters: 1),
                floor: .init(level: 1),
                speed: LocationSpeedEstimate(metersPerSecond: 0, accuracyMetersPerSecond: 0),
                course: LocationCourseEstimate(degrees: 360, accuracyDegrees: 1),
                sourceInformation: .init(simulatedBySoftware: false, producedByAccessory: false)))
        }
        let atDestination = try #require(LocationRecordedLocation(
            latencyMilliseconds: 10052,
            coordinateOffset: LocationHorizontalOffset.encode(destination, relativeTo: origin, format: .meters),
            horizontalAccuracyMeters: 4,
            altitudeOffset: LocationAltitudeOffset(meters: 12, ellipsoidalMeters: 13, accuracyMeters: 2)))
        let session = try LocationSession(
            timestampOrigin: .observed(#require(TimestampOrigin("2030-01-01T00:00:00.000Z"))),
            events: [
                .batch(delayMilliseconds: 50, locations: [atOrigin(latency: 50)]),
                .failure(delayMilliseconds: 5000, error: #require(NSErrorSnapshot(
                    domain: "kCLErrorDomain", code: 1,
                    userInfo: ["reason": .string("offline"), "retry": .boolean(true)]))),
                .batch(delayMilliseconds: 2, locations: [atDestination]),
            ])
        return try LocationRecording(
            horizontal: space,
            altitudeOrigin: LocationAltitudeOrigin(meters: .observed(100), ellipsoidalMeters: .observed(110)),
            initial: .init(
                timestampOrigin: #require(TimestampOrigin("2030-01-01T00:00:00.000Z")),
                location: atOrigin(latency: 1000)),
            sessions: [session], access: access())
    }

    static func degrees() throws -> LocationRecording {
        let origin = try #require(LocationCoordinate(latitudeDegrees: 80, longitudeDegrees: 20))
        let point = try #require(LocationRecordedLocation(
            latencyMilliseconds: 0,
            coordinateOffset: .degrees(latitudeDegrees: 20, longitudeDegrees: 0), horizontalAccuracyMeters: 5))
        return try LocationRecording(
            horizontal: .init(format: .degrees, origin: .observed(origin)),
            initial: .init(timestampOrigin: #require(TimestampOrigin("2030-01-01T00:00:00.000Z")),
                           location: point),
            sessions: [], access: access())
    }
}
