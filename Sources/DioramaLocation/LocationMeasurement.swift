import CoreLocation
import DioramaCore
import Foundation

/// A valid vertical measurement in two independent height reference frames.
struct LocationVerticalEstimate: Equatable, Sendable {
    /// Height above approximate mean sea level, in meters.
    let orthometricAltitudeMeters: Double
    /// Height above the WGS84 ellipsoid, in meters.
    let ellipsoidalAltitudeMeters: Double
    /// Positive vertical uncertainty, in meters.
    let accuracyMeters: Double

    /// Creates a vertical measurement when both heights and its accuracy are valid.
    init?(orthometricAltitudeMeters: Double, ellipsoidalAltitudeMeters: Double, accuracyMeters: Double) {
        guard orthometricAltitudeMeters.isFinite, ellipsoidalAltitudeMeters.isFinite,
              accuracyMeters.isFinite, accuracyMeters > 0
        else { return nil }
        self.orthometricAltitudeMeters = orthometricAltitudeMeters
        self.ellipsoidalAltitudeMeters = ellipsoidalAltitudeMeters
        self.accuracyMeters = accuracyMeters
    }
}

/// A valid speed and its uncertainty, both in meters per second.
struct LocationSpeedEstimate: Equatable, Sendable {
    /// Nonnegative speed.
    let metersPerSecond: Double
    /// Nonnegative speed uncertainty.
    let accuracyMetersPerSecond: Double

    /// Creates a speed estimate when both numbers are finite and nonnegative.
    init?(metersPerSecond: Double, accuracyMetersPerSecond: Double) {
        guard metersPerSecond.isFinite, metersPerSecond >= 0,
              accuracyMetersPerSecond.isFinite, accuracyMetersPerSecond >= 0
        else { return nil }
        self.metersPerSecond = metersPerSecond
        self.accuracyMetersPerSecond = accuracyMetersPerSecond
    }
}

/// A valid course and its uncertainty, both in degrees.
struct LocationCourseEstimate: Equatable, Sendable {
    /// Course clockwise from true north, canonicalized to `0..<360`.
    let degrees: Double
    /// Nonnegative course uncertainty.
    let accuracyDegrees: Double

    /// Creates a course estimate when both numbers are finite and valid.
    init?(degrees: Double, accuracyDegrees: Double) {
        guard degrees.isFinite, (0...360).contains(degrees),
              accuracyDegrees.isFinite, accuracyDegrees >= 0
        else { return nil }
        self.degrees = degrees == 360 ? 0 : degrees
        self.accuracyDegrees = accuracyDegrees
    }
}

/// Optional Core Location provenance, retaining absence separately from false flags.
struct LocationSourceInformation: Equatable, Sendable {
    /// Whether software supplied a simulated location.
    let simulatedBySoftware: Bool
    /// Whether an attached accessory supplied the location.
    let producedByAccessory: Bool
}

/// Validated measurements prepared independently of the native consumer object.
/// Replay-fidelity options do not affect which measurements this value retains.
struct LocationMeasurement: Equatable, Sendable {
    /// WGS84 coordinate; longitude is canonicalized to `[-180, 180)`.
    let coordinate: CLLocationCoordinate2D
    /// Nonnegative horizontal uncertainty, in meters.
    let horizontalAccuracyMeters: Double
    /// Orthometric and ellipsoidal heights, present only with valid vertical accuracy.
    let vertical: LocationVerticalEstimate?
    /// Logical building floor, independent of vertical measurement availability.
    let floorLevel: Int?
    /// Speed and uncertainty, when valid.
    let speed: LocationSpeedEstimate?
    /// Course and uncertainty, when valid.
    let course: LocationCourseEstimate?
    /// Time when the position was measured, independent of callback delivery.
    let timestamp: Date
    /// Source flags retained without storing a native object.
    let sourceInformation: LocationSourceInformation?

    /// Creates a strict location value from already interpreted measurements.
    /// Returns nil for an invalid coordinate, horizontal accuracy, or timestamp.
    init?(
        coordinate: CLLocationCoordinate2D,
        horizontalAccuracyMeters: Double,
        vertical: LocationVerticalEstimate? = nil,
        floorLevel: Int? = nil,
        speed: LocationSpeedEstimate? = nil,
        course: LocationCourseEstimate? = nil,
        timestamp: Date,
        sourceInformation: LocationSourceInformation? = nil)
    {
        guard coordinate.latitude.isFinite, (-90...90).contains(coordinate.latitude),
              coordinate.longitude.isFinite, (-180...180).contains(coordinate.longitude),
              horizontalAccuracyMeters.isFinite, horizontalAccuracyMeters >= 0,
              StableTimeCodec.roundedToMillisecond(timestamp) != nil
        else { return nil }

        self.coordinate = CLLocationCoordinate2D(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude == 180 ? -180 : coordinate.longitude)
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.vertical = vertical
        self.floorLevel = floorLevel
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
        self.sourceInformation = sourceInformation
    }

    /// Creates a value from Core Location scalar fields, treating its negative
    /// speed/course and nonpositive vertical-accuracy sentinels as absence.
    /// Returns nil when a present measurement contains an invalid number.
    init?(
        coordinate: CLLocationCoordinate2D,
        horizontalAccuracyMeters: Double,
        orthometricAltitudeMeters: Double,
        ellipsoidalAltitudeMeters: Double,
        verticalAccuracyMeters: Double,
        floorLevel: Int? = nil,
        speedMetersPerSecond: Double,
        speedAccuracyMetersPerSecond: Double,
        courseDegrees: Double,
        courseAccuracyDegrees: Double,
        timestamp: Date,
        sourceInformation: LocationSourceInformation? = nil)
    {
        guard case let .accepted(vertical) = Self.nativeVertical(
                  orthometric: orthometricAltitudeMeters,
                  ellipsoidal: ellipsoidalAltitudeMeters,
                  accuracy: verticalAccuracyMeters),
            case let .accepted(speed) = Self.nativeSpeed(
                value: speedMetersPerSecond, accuracy: speedAccuracyMetersPerSecond),
            case let .accepted(course) = Self.nativeCourse(
                value: courseDegrees, accuracy: courseAccuracyDegrees)
        else { return nil }

        self.init(
            coordinate: coordinate, horizontalAccuracyMeters: horizontalAccuracyMeters,
            vertical: vertical, floorLevel: floorLevel, speed: speed, course: course,
            timestamp: timestamp, sourceInformation: sourceInformation)
    }

    private static func nativeVertical(
        orthometric: Double,
        ellipsoidal: Double,
        accuracy: Double) -> NativeMeasurement<LocationVerticalEstimate>
    {
        guard accuracy.isFinite else { return .invalid }
        guard accuracy > 0 else { return .accepted(nil) }
        guard let estimate = LocationVerticalEstimate(
            orthometricAltitudeMeters: orthometric,
            ellipsoidalAltitudeMeters: ellipsoidal,
            accuracyMeters: accuracy)
        else { return .invalid }
        return .accepted(estimate)
    }

    private static func nativeSpeed(value: Double, accuracy: Double) -> NativeMeasurement<LocationSpeedEstimate> {
        guard value.isFinite else { return .invalid }
        guard value >= 0 else { return .accepted(nil) }
        guard accuracy.isFinite else { return .invalid }
        guard accuracy >= 0 else { return .accepted(nil) }
        guard let estimate = LocationSpeedEstimate(
            metersPerSecond: value, accuracyMetersPerSecond: accuracy)
        else { return .invalid }
        return .accepted(estimate)
    }

    private static func nativeCourse(value: Double, accuracy: Double) -> NativeMeasurement<LocationCourseEstimate> {
        guard value.isFinite else { return .invalid }
        guard value >= 0 else { return .accepted(nil) }
        guard accuracy.isFinite else { return .invalid }
        guard accuracy >= 0 else { return .accepted(nil) }
        guard let estimate = LocationCourseEstimate(degrees: value, accuracyDegrees: accuracy)
        else { return .invalid }
        return .accepted(estimate)
    }

    /// Compares semantic fields without depending on native coordinate identity.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.horizontalAccuracyMeters == rhs.horizontalAccuracyMeters
            && lhs.vertical == rhs.vertical
            && lhs.floorLevel == rhs.floorLevel
            && lhs.speed == rhs.speed
            && lhs.course == rhs.course
            && lhs.timestamp == rhs.timestamp
            && lhs.sourceInformation == rhs.sourceInformation
    }
}

private enum NativeMeasurement<Value> {
    case invalid
    case accepted(Value?)
}
