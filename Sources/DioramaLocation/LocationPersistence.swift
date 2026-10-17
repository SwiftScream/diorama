import DioramaCore
import DioramaPersistence
import Foundation

/// The version-one Location payload, independent of JSON transport.
enum LocationPersistence {
    static let schemaVersion: UInt32 = 1

    static let registration = PersistentSystemRegistration(
        currentSchemaVersion: schemaVersion,
        payloadType: LocationRecording.self,
        encode: { attachment in
            do {
                return try LocationTracks.recording(in: attachment)
            } catch {
                throw PersistentSystemEncodingError.invalidTrackLayout(attachment.id)
            }
        },
        decode: { payload, key in
            try LocationTracks.attachment(named: key.rawValue, recording: payload)
        })
}

private func malformed(_ decoder: any Decoder, _ reason: String) -> DecodingError {
    .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: reason))
}

private enum MeasurementOriginCodingKey: String, CodingKey {
    case override
}

/// These overloads preserve the already selected canonical Double on a round trip.
/// Decimal controls JSON spelling; it must not perform another semantic normalization.
private extension KeyedEncodingContainer {
    mutating func encodeMeasurement(
        _ value: Double, precision: LocationPrecision = .measurement, forKey key: Key) throws
    {
        if let decimal = try precision.encodingDecimal(for: value, codingPath: codingPath + [key]) {
            try encode(decimal, forKey: key)
        } else {
            try encode(value, forKey: key)
        }
    }

    mutating func encodeMeasurement(
        _ origin: OverridableValue<Double>, forKey key: Key) throws
    {
        // OverridableValue<Decimal> calls Decimal.encode directly, bypassing JSON's
        // numeric specialization. Keep Decimal values in keyed encode calls here.
        switch origin {
        case let .observed(value):
            try encodeMeasurement(value, forKey: key)
        case let .override(value):
            var tagged = nestedContainer(keyedBy: MeasurementOriginCodingKey.self, forKey: key)
            try tagged.encodeMeasurement(value, forKey: .override)
        }
    }
}

private extension LocationPrecision {
    func encodingDecimal(for value: Double, codingPath: [any CodingKey]) throws -> Decimal? {
        guard let decimal = decimalRepresentation(of: value) else {
            // A huge finite whole Double is already exact at the required decimal scale.
            guard value.isFinite, value.rounded() == value else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: codingPath, debugDescription: "Measurement is not a finite canonical value"))
            }
            return nil
        }
        guard Double(NSDecimalNumber(decimal: decimal).stringValue) == value else {
            throw EncodingError.invalidValue(value, .init(
                codingPath: codingPath, debugDescription: "Measurement must be normalized before encoding"))
        }
        return decimal
    }
}

extension LocationCoordinate: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case latitudeDegrees, longitudeDegrees
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        let latitude = try fields.decode(Double.self, forKey: .latitudeDegrees)
        let longitude = try fields.decode(Double.self, forKey: .longitudeDegrees)
        guard let value = Self(latitudeDegrees: latitude, longitudeDegrees: longitude) else {
            throw malformed(decoder, "Invalid WGS84 coordinate")
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encodeMeasurement(latitudeDegrees, precision: .coordinate, forKey: .latitudeDegrees)
        try fields.encodeMeasurement(longitudeDegrees, precision: .coordinate, forKey: .longitudeDegrees)
    }
}

extension LocationHorizontalOffset: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case eastMeters, northMeters, latitudeDegrees, longitudeDegrees
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        if fields.contains(.eastMeters), fields.contains(.northMeters),
           !fields.contains(.latitudeDegrees), !fields.contains(.longitudeDegrees)
        {
            let east = try fields.decode(Double.self, forKey: .eastMeters)
            let north = try fields.decode(Double.self, forKey: .northMeters)
            guard let offset = Self(normalizing: .meters(eastMeters: east, northMeters: north))
            else { throw malformed(decoder, "Invalid meter offset") }
            self = offset
        } else if fields.contains(.latitudeDegrees), fields.contains(.longitudeDegrees),
                  !fields.contains(.eastMeters), !fields.contains(.northMeters)
        {
            let latitude = try fields.decode(Double.self, forKey: .latitudeDegrees)
            let longitude = try fields.decode(Double.self, forKey: .longitudeDegrees)
            guard let offset = Self(normalizing: .degrees(latitudeDegrees: latitude, longitudeDegrees: longitude))
            else { throw malformed(decoder, "Invalid degree offset") }
            self = offset
        } else {
            throw malformed(decoder, "Offset fields do not identify one format")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .meters(east, north):
            try fields.encodeMeasurement(east, forKey: .eastMeters)
            try fields.encodeMeasurement(north, forKey: .northMeters)
        case let .degrees(latitude, longitude):
            try fields.encodeMeasurement(latitude, precision: .coordinate, forKey: .latitudeDegrees)
            try fields.encodeMeasurement(longitude, precision: .coordinate, forKey: .longitudeDegrees)
        }
    }
}

extension LocationAltitudeOrigin: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case meters, ellipsoidalMeters
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        guard let value = try Self(
            meters: fields.decode(OverridableValue<Double>.self, forKey: .meters),
            ellipsoidalMeters: fields.decode(OverridableValue<Double>.self, forKey: .ellipsoidalMeters))
        else { throw malformed(decoder, "Invalid altitude origin") }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encodeMeasurement(meters, forKey: .meters)
        try fields.encodeMeasurement(ellipsoidalMeters, forKey: .ellipsoidalMeters)
    }
}

extension LocationRecordedFloor: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case level
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        try self.init(level: fields.decode(Int.self, forKey: .level))
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(level, forKey: .level)
    }
}

/// JSON altitude offsets omit accuracy, which is a sibling in the location object.
private struct AltitudeValues: Codable {
    let meters: Double
    let ellipsoidalMeters: Double

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case meters, ellipsoidalMeters
    }

    init(_ offset: LocationAltitudeOffset) {
        meters = offset.meters
        ellipsoidalMeters = offset.ellipsoidalMeters
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        meters = try fields.decode(Double.self, forKey: .meters)
        ellipsoidalMeters = try fields.decode(Double.self, forKey: .ellipsoidalMeters)
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encodeMeasurement(meters, forKey: .meters)
        try fields.encodeMeasurement(ellipsoidalMeters, forKey: .ellipsoidalMeters)
    }
}

extension LocationSpeedEstimate: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metersPerSecond, accuracyMetersPerSecond
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        let speed = try fields.decode(Double.self, forKey: .metersPerSecond)
        let accuracy = try fields.decode(Double.self, forKey: .accuracyMetersPerSecond)
        guard let value = Self(metersPerSecond: speed, accuracyMetersPerSecond: accuracy) else {
            throw malformed(decoder, "Invalid speed")
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encodeMeasurement(metersPerSecond, forKey: .metersPerSecond)
        try fields.encodeMeasurement(accuracyMetersPerSecond, forKey: .accuracyMetersPerSecond)
    }
}

extension LocationCourseEstimate: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case degrees, accuracyDegrees
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        let degrees = try fields.decode(Double.self, forKey: .degrees)
        let accuracy = try fields.decode(Double.self, forKey: .accuracyDegrees)
        guard let value = Self(degrees: degrees, accuracyDegrees: accuracy) else {
            throw malformed(decoder, "Invalid course")
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encodeMeasurement(degrees, forKey: .degrees)
        try fields.encodeMeasurement(accuracyDegrees, forKey: .accuracyDegrees)
    }
}

extension LocationSourceInformation: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case isSimulatedBySoftware, isProducedByAccessory
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        try self.init(
            simulatedBySoftware: fields.decode(Bool.self, forKey: .isSimulatedBySoftware),
            producedByAccessory: fields.decode(Bool.self, forKey: .isProducedByAccessory))
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(simulatedBySoftware, forKey: .isSimulatedBySoftware)
        try fields.encode(producedByAccessory, forKey: .isProducedByAccessory)
    }
}

extension LocationRecordedLocation: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case latency, coordinateOffset, horizontalAccuracyMeters, altitudeOffset, verticalAccuracyMeters
        case floor, speed, course, sourceInformation
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        guard let latency = try StableTimeCodec.parseDuration(fields.decode(String.self, forKey: .latency))
        else { throw malformed(decoder, "Invalid location latency") }
        let altitude: LocationAltitudeOffset?
        if fields.contains(.altitudeOffset), fields.contains(.verticalAccuracyMeters) {
            let values = try fields.decode(AltitudeValues.self, forKey: .altitudeOffset)
            guard let value = try LocationAltitudeOffset(
                meters: values.meters, ellipsoidalMeters: values.ellipsoidalMeters,
                accuracyMeters: fields.decode(Double.self, forKey: .verticalAccuracyMeters))
            else { throw malformed(decoder, "Invalid altitude offset or accuracy") }
            altitude = value
        } else if !fields.contains(.altitudeOffset), !fields.contains(.verticalAccuracyMeters) {
            altitude = nil
        } else {
            throw malformed(decoder, "Altitude offset and vertical accuracy must occur together")
        }
        guard let value = try Self(
            latencyMilliseconds: latency,
            coordinateOffset: fields.decode(LocationHorizontalOffset.self, forKey: .coordinateOffset),
            horizontalAccuracyMeters: fields.decode(Double.self, forKey: .horizontalAccuracyMeters),
            altitudeOffset: altitude,
            floor: fields.contains(.floor) ? fields.decode(LocationRecordedFloor.self, forKey: .floor) : nil,
            speed: fields.contains(.speed) ? fields.decode(LocationSpeedEstimate.self, forKey: .speed) : nil,
            course: fields.contains(.course) ? fields.decode(LocationCourseEstimate.self, forKey: .course) : nil,
            sourceInformation: fields.contains(.sourceInformation)
                ? fields.decode(LocationSourceInformation.self, forKey: .sourceInformation) : nil)
        else { throw malformed(decoder, "Invalid location") }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(StableTimeCodec.formatDuration(latencyMilliseconds), forKey: .latency)
        try fields.encode(coordinateOffset, forKey: .coordinateOffset)
        try fields.encodeMeasurement(horizontalAccuracyMeters, forKey: .horizontalAccuracyMeters)
        if let altitudeOffset {
            try fields.encode(AltitudeValues(altitudeOffset), forKey: .altitudeOffset)
            try fields.encodeMeasurement(altitudeOffset.accuracyMeters, forKey: .verticalAccuracyMeters)
        }
        try fields.encodeIfPresent(floor, forKey: .floor)
        try fields.encodeIfPresent(speed, forKey: .speed)
        try fields.encodeIfPresent(course, forKey: .course)
        try fields.encodeIfPresent(sourceInformation, forKey: .sourceInformation)
    }
}

extension LocationInitialSnapshot: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case timestampOrigin, location
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        try self.init(
            timestampOrigin: fields.decode(TimestampOriginPayload.self, forKey: .timestampOrigin).value,
            location: fields.decode(LocationRecordedLocation.self, forKey: .location))
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(TimestampOriginPayload(timestampOrigin), forKey: .timestampOrigin)
        try fields.encode(location, forKey: .location)
    }
}

extension LocationSessionEvent: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, delay, locations, error
    }

    private enum Kind: String, Codable {
        case batch, failure
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        guard let delay = try StableTimeCodec.parseDuration(fields.decode(String.self, forKey: .delay)),
              delay >= 0
        else { throw malformed(decoder, "Invalid delivery delay") }
        switch try fields.decode(Kind.self, forKey: .kind) {
        case .batch:
            guard !fields.contains(.error) else { throw malformed(decoder, "Batch has failure fields") }
            self = try .batch(
                delayMilliseconds: delay,
                locations: fields.decode([LocationRecordedLocation].self, forKey: .locations))
        case .failure:
            guard !fields.contains(.locations) else { throw malformed(decoder, "Failure has batch fields") }
            self = try .failure(
                delayMilliseconds: delay,
                error: fields.decode(NSErrorSnapshotPayload.self, forKey: .error).snapshot())
        }
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(StableTimeCodec.formatDuration(delayMilliseconds), forKey: .delay)
        switch self {
        case let .batch(_, locations):
            try fields.encode(Kind.batch, forKey: .kind)
            try fields.encode(locations, forKey: .locations)
        case let .failure(_, error):
            try fields.encode(Kind.failure, forKey: .kind)
            try fields.encode(NSErrorSnapshotPayload(error), forKey: .error)
        }
    }
}

extension LocationSession: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case timestampOrigin, events, conclusion
    }

    private enum Conclusion: String, Codable {
        case openAtRecordingHorizon
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        guard try fields.decode(Conclusion.self, forKey: .conclusion) == .openAtRecordingHorizon
        else { throw malformed(decoder, "Unsupported session conclusion") }
        self = try Self(
            timestampOrigin: fields.contains(.timestampOrigin)
                ? fields.decode(
                    OverridableValue<TimestampOriginPayload>.self, forKey: .timestampOrigin).map(\.value) : nil,
            events: fields.decode([LocationSessionEvent].self, forKey: .events))
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encodeIfPresent(timestampOrigin?.map(TimestampOriginPayload.init), forKey: .timestampOrigin)
        try fields.encode(events, forKey: .events)
        try fields.encode(Conclusion.openAtRecordingHorizon, forKey: .conclusion)
    }
}

extension LocationRecordedAccessState: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case servicesEnabled, permission, accuracy
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        try self.init(
            servicesEnabled: fields.decode(Bool.self, forKey: .servicesEnabled),
            permission: fields.decode(LocationPermission.self, forKey: .permission),
            accuracy: fields.decode(LocationAccuracy.self, forKey: .accuracy))
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(servicesEnabled, forKey: .servicesEnabled)
        try fields.encode(permission, forKey: .permission)
        try fields.encode(accuracy, forKey: .accuracy)
    }
}

extension LocationAccessNotification: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case delay, state
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        guard let delay = try StableTimeCodec.parseDuration(fields.decode(String.self, forKey: .delay)),
              delay >= 0
        else { throw malformed(decoder, "Invalid access delivery delay") }
        try self.init(
            delayMilliseconds: delay,
            state: fields.decode(LocationRecordedAccessState.self, forKey: .state))
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(StableTimeCodec.formatDuration(delayMilliseconds), forKey: .delay)
        try fields.encode(state, forKey: .state)
    }
}

extension LocationAccessRequestSegment: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case request, notifications
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        try self.init(
            request: fields.decode(LocationAuthorizationRequest.self, forKey: .request),
            notifications: fields.decode([LocationAccessNotification].self, forKey: .notifications))
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(request, forKey: .request)
        try fields.encode(notifications, forKey: .notifications)
    }
}

extension LocationAccessRecording: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case initialState, initialNotifications, requests
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        self = try Self(
            initialState: fields.decode(LocationRecordedAccessState.self, forKey: .initialState),
            initialNotifications: fields.decode([LocationAccessNotification].self, forKey: .initialNotifications),
            requests: fields.decode([LocationAccessRequestSegment].self, forKey: .requests))
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(initialState, forKey: .initialState)
        try fields.encode(initialNotifications, forKey: .initialNotifications)
        try fields.encode(requests, forKey: .requests)
    }
}

extension LocationRecording: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case coordinateFormat, coordinateOrigin, altitudeOrigin
        case initial, sessions, access
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        let horizontal: LocationHorizontalSpace?
        if fields.contains(.coordinateOrigin), fields.contains(.coordinateFormat) {
            horizontal = try .init(
                format: fields.decode(LocationCoordinateFormat.self, forKey: .coordinateFormat),
                origin: fields.decode(OverridableValue<LocationCoordinate>.self, forKey: .coordinateOrigin))
        } else if !fields.contains(.coordinateOrigin), !fields.contains(.coordinateFormat) {
            horizontal = nil
        } else {
            throw malformed(decoder, "Coordinate format and origin must occur together")
        }
        self = try Self(
            horizontal: horizontal,
            altitudeOrigin: fields.contains(.altitudeOrigin)
                ? fields.decode(LocationAltitudeOrigin.self, forKey: .altitudeOrigin) : nil,
            initial: fields.contains(.initial)
                ? fields.decode(LocationInitialSnapshot.self, forKey: .initial) : nil,
            sessions: fields.decode([LocationSession].self, forKey: .sessions),
            access: fields.decode(LocationAccessRecording.self, forKey: .access))
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        if let horizontal {
            try fields.encode(horizontal.format, forKey: .coordinateFormat)
            try fields.encode(horizontal.origin, forKey: .coordinateOrigin)
        }
        try fields.encodeIfPresent(altitudeOrigin, forKey: .altitudeOrigin)
        try fields.encodeIfPresent(initial, forKey: .initial)
        try fields.encode(sessions, forKey: .sessions)
        try fields.encode(access, forKey: .access)
    }
}
