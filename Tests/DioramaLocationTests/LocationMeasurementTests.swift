import CoreLocation
@testable import DioramaLocation
import Foundation
import Testing

struct LocationMeasurementTests {
    @Test
    func `preserves floor and independent altitude references`() throws {
        let vertical = try #require(LocationVerticalEstimate(
            orthometricAltitudeMeters: 42,
            ellipsoidalAltitudeMeters: 73,
            accuracyMeters: 3))
        let source = LocationSourceInformation(
            simulatedBySoftware: false, producedByAccessory: false)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let location = try #require(LocationMeasurement(
            coordinate: CLLocationCoordinate2D(latitude: 37, longitude: 180),
            horizontalAccuracyMeters: 0, vertical: vertical, floorLevel: -2,
            timestamp: date, sourceInformation: source))

        #expect(location.coordinate.longitude == -180)
        #expect(location.vertical?.orthometricAltitudeMeters == 42)
        #expect(location.vertical?.ellipsoidalAltitudeMeters == 73)
        #expect(location.floorLevel == -2)
        #expect(location.sourceInformation == source)
        #expect(location.timestamp == date)
        #expect(try #require(LocationMeasurement(
            coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -180),
            horizontalAccuracyMeters: 0, vertical: vertical, floorLevel: -2,
            timestamp: date, sourceInformation: source)) == location)
    }

    @Test
    func `source absence differs from two false flags`() throws {
        let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let date = Date(timeIntervalSince1970: 0)
        let absent = try #require(LocationMeasurement(
            coordinate: coordinate, horizontalAccuracyMeters: 1, timestamp: date))
        let falseFlags = try #require(LocationMeasurement(
            coordinate: coordinate, horizontalAccuracyMeters: 1, timestamp: date,
            sourceInformation: LocationSourceInformation(
                simulatedBySoftware: false, producedByAccessory: false)))
        #expect(absent.sourceInformation == nil)
        #expect(falseFlags.sourceInformation != nil)
        #expect(absent != falseFlags)
    }

    @Test
    func `rejects invalid required location fields`() {
        let date = Date(timeIntervalSince1970: 0)
        for coordinate in [
            CLLocationCoordinate2D(latitude: .nan, longitude: 0),
            CLLocationCoordinate2D(latitude: 91, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: .infinity),
            CLLocationCoordinate2D(latitude: 0, longitude: 181),
        ] {
            #expect(LocationMeasurement(
                coordinate: coordinate, horizontalAccuracyMeters: 1,
                timestamp: date) == nil)
        }
        let valid = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        for accuracy in [Double.nan, -Double.infinity, -1] {
            #expect(LocationMeasurement(
                coordinate: valid, horizontalAccuracyMeters: accuracy,
                timestamp: date) == nil)
        }
        #expect(LocationMeasurement(
            coordinate: valid, horizontalAccuracyMeters: 1,
            timestamp: Date(timeIntervalSince1970: .infinity)) == nil)
    }

    @Test
    func `validates grouped vertical speed and course values`() {
        #expect(LocationVerticalEstimate(
            orthometricAltitudeMeters: 1, ellipsoidalAltitudeMeters: 2,
            accuracyMeters: 0) == nil)
        #expect(LocationVerticalEstimate(
            orthometricAltitudeMeters: .nan, ellipsoidalAltitudeMeters: 2,
            accuracyMeters: 1) == nil)
        #expect(LocationSpeedEstimate(
            metersPerSecond: -1, accuracyMetersPerSecond: 0) == nil)
        #expect(LocationSpeedEstimate(
            metersPerSecond: 0, accuracyMetersPerSecond: -.infinity) == nil)
        #expect(LocationCourseEstimate(degrees: -1, accuracyDegrees: 0) == nil)
        #expect(LocationCourseEstimate(degrees: 361, accuracyDegrees: 0) == nil)
        #expect(LocationCourseEstimate(degrees: 0, accuracyDegrees: -1) == nil)
        #expect(LocationCourseEstimate(degrees: 360, accuracyDegrees: 0)?.degrees == 0)
    }

    @Test
    func `native invalid sentinels become absent measurements`() throws {
        let location = try #require(LocationMeasurement(
            coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2),
            horizontalAccuracyMeters: 4,
            orthometricAltitudeMeters: 10,
            ellipsoidalAltitudeMeters: 20,
            verticalAccuracyMeters: 0,
            floorLevel: 0,
            speedMetersPerSecond: -1,
            speedAccuracyMetersPerSecond: -1,
            courseDegrees: -1,
            courseAccuracyDegrees: -1,
            timestamp: Date(timeIntervalSince1970: 10)))
        #expect(location.vertical == nil)
        #expect(location.floorLevel == 0)
        #expect(location.speed == nil)
        #expect(location.course == nil)

        let valid = try #require(LocationMeasurement(
            coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2),
            horizontalAccuracyMeters: 4,
            orthometricAltitudeMeters: 10,
            ellipsoidalAltitudeMeters: 20,
            verticalAccuracyMeters: 2,
            speedMetersPerSecond: 3,
            speedAccuracyMetersPerSecond: 0,
            courseDegrees: 360,
            courseAccuracyDegrees: 1,
            timestamp: Date(timeIntervalSince1970: 10)))
        #expect(valid.vertical?.ellipsoidalAltitudeMeters == 20)
        #expect(valid.speed?.metersPerSecond == 3)
        #expect(valid.course?.degrees == 0)
    }
}
