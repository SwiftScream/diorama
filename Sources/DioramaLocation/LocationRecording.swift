import CoreLocation
import DioramaCore
import Foundation

/// Safe structural failures for a Location recording or edited payload.
enum LocationRecordingError: Error, Equatable, Sendable {
    case invalidTrackLayout
    case invalidCoordinate
    case mixedCoordinateFormats
    case missingCoordinateOrigin
    case unusedCoordinateOrigin
    case missingVerticalOrigins
    case unusedVerticalOrigins
    case invalidMeasurement(position: Int)
    case invalidDeliveryDelay(position: Int)
    case cumulativeOverflow(position: Int)
    case unsupportedAuthorization
}

/// Two independent altitude origins, each retaining its own override marker.
struct LocationAltitudeOrigin: Equatable, Sendable {
    let meters: OverridableValue<Double>
    let ellipsoidalMeters: OverridableValue<Double>

    init?(meters: OverridableValue<Double>, ellipsoidalMeters: OverridableValue<Double>) {
        guard meters.value.isFinite, ellipsoidalMeters.value.isFinite else { return nil }
        self.meters = meters.map(LocationPrecision.millimeters)
        self.ellipsoidalMeters = ellipsoidalMeters.map(LocationPrecision.millimeters)
    }
}

/// Altitude offsets and positive accuracy form one strict optional measurement.
struct LocationAltitudeOffset: Equatable, Sendable {
    let meters: Double
    let ellipsoidalMeters: Double
    let accuracyMeters: Double

    init?(meters: Double, ellipsoidalMeters: Double, accuracyMeters: Double) {
        guard meters.isFinite, ellipsoidalMeters.isFinite,
              accuracyMeters.isFinite, accuracyMeters > 0
        else { return nil }
        self.meters = LocationPrecision.millimeters(meters)
        self.ellipsoidalMeters = LocationPrecision.millimeters(ellipsoidalMeters)
        self.accuracyMeters = max(0.001, LocationPrecision.millimeters(accuracyMeters))
    }
}

/// A logical building floor, independent of altitude availability.
struct LocationRecordedFloor: Equatable, Sendable {
    let level: Int
}

/// One stable location, including its signed age relative to logical delivery time.
struct LocationRecordedLocation: Equatable, Sendable {
    let latencyMilliseconds: Int64
    let coordinateOffset: LocationHorizontalOffset
    let horizontalAccuracyMeters: Double
    let altitudeOffset: LocationAltitudeOffset?
    let floor: LocationRecordedFloor?
    let speed: LocationSpeedEstimate?
    let course: LocationCourseEstimate?
    let sourceInformation: LocationSourceInformation?

    init?(
        latencyMilliseconds: Int64,
        coordinateOffset: LocationHorizontalOffset,
        horizontalAccuracyMeters: Double,
        altitudeOffset: LocationAltitudeOffset? = nil,
        floor: LocationRecordedFloor? = nil,
        speed: LocationSpeedEstimate? = nil,
        course: LocationCourseEstimate? = nil,
        sourceInformation: LocationSourceInformation? = nil)
    {
        guard horizontalAccuracyMeters.isFinite, horizontalAccuracyMeters >= 0,
              let coordinateOffset = LocationHorizontalOffset(normalizing: coordinateOffset)
        else { return nil }
        self.latencyMilliseconds = latencyMilliseconds
        self.coordinateOffset = coordinateOffset
        self.horizontalAccuracyMeters = LocationPrecision.millimeters(horizontalAccuracyMeters)
        self.altitudeOffset = altitudeOffset
        self.floor = floor
        self.speed = speed.flatMap {
            LocationSpeedEstimate(
                metersPerSecond: LocationPrecision.millimeters($0.metersPerSecond),
                accuracyMetersPerSecond: LocationPrecision.millimeters($0.accuracyMetersPerSecond))
        }
        self.course = course.flatMap {
            LocationCourseEstimate(
                degrees: LocationPrecision.courseDegrees($0.degrees),
                accuracyDegrees: LocationPrecision.courseDegrees($0.accuracyDegrees))
        }
        self.sourceInformation = sourceInformation
    }

    /// Scheduled delivery offsets determine timestamps; actual callback lateness does not.
    func timestamp(relativeTo origin: TimestampOrigin, deliveryMilliseconds: Int64) -> Date? {
        let (offset, overflow) = deliveryMilliseconds.subtractingReportingOverflow(latencyMilliseconds)
        guard deliveryMilliseconds >= 0, !overflow else { return nil }
        return origin.advanced(by: offset)
    }
}

/// The attachment's initial location uses the same value with delivery offset zero.
struct LocationInitialSnapshot: Equatable, Sendable {
    let timestampOrigin: TimestampOrigin
    let location: LocationRecordedLocation

    init(timestampOrigin: TimestampOrigin, location: LocationRecordedLocation) throws(LocationRecordingError) {
        guard location.timestamp(relativeTo: timestampOrigin, deliveryMilliseconds: 0) != nil else {
            throw .invalidMeasurement(position: 0)
        }
        self.timestampOrigin = timestampOrigin
        self.location = location
    }
}

/// One observed native callback; failures do not conclude the session.
enum LocationSessionEvent: Equatable, Sendable {
    case batch(delayMilliseconds: Int64, locations: [LocationRecordedLocation])
    case failure(delayMilliseconds: Int64, error: NSErrorSnapshot)

    var delayMilliseconds: Int64 {
        switch self {
        case let .batch(delay, _), let .failure(delay, _): delay
        }
    }
}

/// One strictly open standard-update session, anchored to session-start wall time.
struct LocationSession: Equatable, Sendable {
    let timestampOrigin: OverridableValue<TimestampOrigin>?
    let events: [LocationSessionEvent]

    init(
        timestampOrigin: OverridableValue<TimestampOrigin>?,
        events: [LocationSessionEvent]) throws(LocationRecordingError)
    {
        var delivery: Int64 = 0
        var locationCount = 0
        for (eventIndex, event) in events.enumerated() {
            guard event.delayMilliseconds >= 0 else { throw .invalidDeliveryDelay(position: eventIndex) }
            let (nextDelivery, deliveryOverflow) = delivery.addingReportingOverflow(event.delayMilliseconds)
            guard !deliveryOverflow else { throw .cumulativeOverflow(position: eventIndex) }
            delivery = nextDelivery
            if case let .batch(_, locations) = event {
                for location in locations {
                    guard let timestampOrigin,
                          location.timestamp(relativeTo: timestampOrigin.value, deliveryMilliseconds: delivery) != nil
                    else { throw .invalidMeasurement(position: locationCount) }
                    locationCount += 1
                }
            }
        }
        guard (locationCount == 0) == (timestampOrigin == nil) else {
            throw .invalidMeasurement(position: 0)
        }
        self.timestampOrigin = timestampOrigin
        self.events = events
    }
}

/// Known semantic status independent of which Apple platform produced it.
enum LocationPermission: String, Codable, Sendable {
    case notDetermined
    case restricted
    case denied
    case whenInUse
    case always

    init?(native: CLAuthorizationStatus) {
        switch native.rawValue {
        case 0: self = .notDetermined
        case 1: self = .restricted
        case 2: self = .denied
        case 3: self = .always
        case 4: self = .whenInUse
        default: return nil
        }
    }
}

enum LocationAccuracy: String, Codable, Sendable {
    case full
    case reduced

    init?(native: CLAccuracyAuthorization) {
        switch native.rawValue {
        case 0: self = .full
        case 1: self = .reduced
        default: return nil
        }
    }
}

/// A complete stable access state, including device service availability.
struct LocationRecordedAccessState: Equatable, Sendable {
    let servicesEnabled: Bool
    let permission: LocationPermission
    let accuracy: LocationAccuracy

    init(servicesEnabled: Bool, permission: LocationPermission, accuracy: LocationAccuracy) {
        self.servicesEnabled = servicesEnabled
        self.permission = permission
        self.accuracy = accuracy
    }

    init(_ native: LocationAccessState) throws(LocationRecordingError) {
        guard let permission = LocationPermission(native: native.permission),
              let accuracy = LocationAccuracy(native: native.accuracy)
        else { throw .unsupportedAuthorization }
        self.init(servicesEnabled: native.servicesEnabled, permission: permission, accuracy: accuracy)
    }
}

/// A complete state installed after one nonnegative successive delay.
struct LocationAccessNotification: Equatable, Sendable {
    let delayMilliseconds: Int64
    let state: LocationRecordedAccessState
}

enum LocationAuthorizationRequest: String, Codable, Sendable {
    case whenInUse
    case always
}

/// One claimable request barrier and notifications anchored to its invocation.
struct LocationAccessRequestSegment: Equatable, Sendable {
    let request: LocationAuthorizationRequest
    let notifications: [LocationAccessNotification]
}

/// The initial observation segment precedes every request barrier.
struct LocationAccessRecording: Equatable, Sendable {
    let initialState: LocationRecordedAccessState
    let initialNotifications: [LocationAccessNotification]
    let requests: [LocationAccessRequestSegment]

    init(
        initialState: LocationRecordedAccessState,
        initialNotifications: [LocationAccessNotification],
        requests: [LocationAccessRequestSegment]) throws(LocationRecordingError)
    {
        try Self.validate(initialNotifications)
        for segment in requests {
            try Self.validate(segment.notifications)
        }
        self.initialState = initialState
        self.initialNotifications = initialNotifications
        self.requests = requests
    }

    private static func validate(_ notifications: [LocationAccessNotification]) throws(LocationRecordingError) {
        var elapsed: Int64 = 0
        for (index, notification) in notifications.enumerated() {
            guard notification.delayMilliseconds >= 0 else { throw .invalidDeliveryDelay(position: index) }
            let (next, overflow) = elapsed.addingReportingOverflow(notification.delayMilliseconds)
            guard !overflow else { throw .cumulativeOverflow(position: index) }
            elapsed = next
        }
    }
}

/// Validated domain content for one named Location attachment.
struct LocationRecording: Equatable, Sendable {
    let horizontal: LocationHorizontalSpace?
    let altitudeOrigin: LocationAltitudeOrigin?
    let initial: LocationInitialSnapshot?
    let sessions: [LocationSession]
    let access: LocationAccessRecording

    init(
        horizontal: LocationHorizontalSpace?,
        altitudeOrigin: LocationAltitudeOrigin? = nil,
        initial: LocationInitialSnapshot? = nil,
        sessions: [LocationSession],
        access: LocationAccessRecording) throws(LocationRecordingError)
    {
        let points = Self.points(initial: initial, sessions: sessions)
        try Self.validateOrigins(
            points: points, horizontal: horizontal,
            altitudeOrigin: altitudeOrigin)
        try Self.validateCoordinates(points: points, horizontal: horizontal)
        self.horizontal = horizontal
        self.altitudeOrigin = altitudeOrigin
        self.initial = initial
        self.sessions = sessions
        self.access = access
    }

    private static func points(
        initial: LocationInitialSnapshot?, sessions: [LocationSession]) -> [LocationRecordedLocation]
    {
        var result: [LocationRecordedLocation] = []
        if let initial {
            result.append(initial.location)
        }
        for session in sessions {
            for event in session.events {
                if case let .batch(_, locations) = event {
                    result += locations
                }
            }
        }
        return result
    }

    private static func validateOrigins(
        points: [LocationRecordedLocation],
        horizontal: LocationHorizontalSpace?,
        altitudeOrigin: LocationAltitudeOrigin?) throws(LocationRecordingError)
    {
        guard points.isEmpty == (horizontal == nil) else {
            throw points.isEmpty ? .unusedCoordinateOrigin : .missingCoordinateOrigin
        }
        let hasAltitude = points.contains { $0.altitudeOffset != nil }
        guard (altitudeOrigin != nil) == hasAltitude else {
            throw hasAltitude ? .missingVerticalOrigins : .unusedVerticalOrigins
        }
        for (index, point) in points.enumerated() {
            guard let offset = point.altitudeOffset else { continue }
            guard let altitudeOrigin,
                  LocationVerticalEstimate(
                      orthometricAltitudeMeters: altitudeOrigin.meters.value + offset.meters,
                      ellipsoidalAltitudeMeters: altitudeOrigin.ellipsoidalMeters.value + offset.ellipsoidalMeters,
                      accuracyMeters: offset.accuracyMeters) != nil
            else { throw .invalidMeasurement(position: index) }
        }
    }

    private static func validateCoordinates(
        points: [LocationRecordedLocation], horizontal: LocationHorizontalSpace?) throws(LocationRecordingError)
    {
        guard let horizontal else { return }
        for point in points {
            guard point.coordinateOffset.format == horizontal.format else {
                throw .mixedCoordinateFormats
            }
            do {
                _ = try horizontal.coordinate(for: point.coordinateOffset)
            } catch {
                throw .invalidCoordinate
            }
        }
    }

    /// Origin editing changes no point offsets or event ordering.
    func relocated(to origin: LocationCoordinate) throws(LocationRecordingError) -> Self {
        guard let horizontal else { throw .missingCoordinateOrigin }
        return try Self(
            horizontal: horizontal.relocated(to: origin),
            altitudeOrigin: altitudeOrigin,
            initial: initial, sessions: sessions, access: access)
    }

    /// Shared normalized materialization for fresh recording observations and replay.
    /// Record adapters use a fresh observed recording here, before authored override merge.
    func measurement(
        for point: LocationRecordedLocation,
        timestampOrigin: TimestampOrigin,
        deliveryMilliseconds: Int64) throws(LocationRecordingError) -> LocationMeasurement
    {
        guard let timestamp = point.timestamp(relativeTo: timestampOrigin, deliveryMilliseconds: deliveryMilliseconds)
        else { throw .invalidMeasurement(position: 0) }
        guard let horizontal,
              let coordinate = try? horizontal.coordinate(for: point.coordinateOffset)
        else { throw .invalidCoordinate }
        let vertical: LocationVerticalEstimate?
        if let offset = point.altitudeOffset {
            guard let altitudeOrigin,
                  let value = LocationVerticalEstimate(
                      orthometricAltitudeMeters: LocationPrecision.millimeters(
                          altitudeOrigin.meters.value + offset.meters),
                      ellipsoidalAltitudeMeters: LocationPrecision.millimeters(
                          altitudeOrigin.ellipsoidalMeters.value + offset.ellipsoidalMeters),
                      accuracyMeters: offset.accuracyMeters)
            else { throw .invalidMeasurement(position: 0) }
            vertical = value
        } else {
            vertical = nil
        }
        guard let measurement = LocationMeasurement(
            coordinate: CLLocationCoordinate2D(
                latitude: coordinate.latitudeDegrees, longitude: coordinate.longitudeDegrees),
            horizontalAccuracyMeters: point.horizontalAccuracyMeters,
            vertical: vertical,
            floorLevel: point.floor?.level,
            speed: point.speed,
            course: point.course,
            timestamp: timestamp,
            sourceInformation: point.sourceInformation)
        else { throw .invalidMeasurement(position: 0) }
        return measurement
    }
}
