import CoreLocation
import DioramaCore
import Foundation

/// The attachment-wide interpretation of every horizontal offset.
enum LocationCoordinateFormat: String, Codable, Sendable {
    case meters
    case degrees
}

/// A canonical WGS84 coordinate with no native object in the stored model.
struct LocationCoordinate: Equatable, Sendable {
    let latitudeDegrees: Double
    let longitudeDegrees: Double

    init?(latitudeDegrees: Double, longitudeDegrees: Double) {
        let point = LocationGeodesy.Coordinate(latitude: latitudeDegrees, longitude: longitudeDegrees)
        guard point.valid else { return nil }
        let canonical = LocationGeodesy.Coordinate(
            latitude: LocationPrecision.coordinateDegrees(point.latitude),
            longitude: LocationPrecision.coordinateDegrees(point.longitude)).canonical
        self.latitudeDegrees = canonical.latitude
        self.longitudeDegrees = canonical.longitude
    }

    init?(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitudeDegrees: coordinate.latitude, longitudeDegrees: coordinate.longitude)
    }

    var geodesy: LocationGeodesy.Coordinate {
        .init(latitude: latitudeDegrees, longitude: longitudeDegrees)
    }
}

/// One offset whose cases cannot mix meter and degree values.
enum LocationHorizontalOffset: Equatable, Sendable {
    case meters(eastMeters: Double, northMeters: Double)
    case degrees(latitudeDegrees: Double, longitudeDegrees: Double)

    init?(normalizing offset: Self) {
        switch offset {
        case let .meters(east, north):
            guard east.isFinite, north.isFinite,
                  hypot(east, north) <= LocationGeodesy.maximumRadius
            else { return nil }
            let east = LocationPrecision.millimeters(east)
            let north = LocationPrecision.millimeters(north)
            guard hypot(east, north) <= LocationGeodesy.maximumRadius else { return nil }
            self = .meters(eastMeters: east, northMeters: north)
        case let .degrees(latitude, longitude):
            guard latitude.isFinite, longitude.isFinite,
                  abs(latitude) <= 180, abs(longitude) <= 180
            else { return nil }
            let latitude = LocationPrecision.coordinateDegrees(latitude)
            let longitude = LocationPrecision.coordinateDegrees(longitude)
            self = .degrees(latitudeDegrees: latitude, longitudeDegrees: longitude == 180 ? -180 : longitude)
        }
    }

    var format: LocationCoordinateFormat {
        switch self {
        case .meters: .meters
        case .degrees: .degrees
        }
    }

    func coordinate(relativeTo origin: LocationCoordinate) throws -> LocationCoordinate {
        let point: LocationGeodesy.Coordinate = switch self {
        case let .meters(east, north):
            try LocationGeodesy.inverse(
                origin: origin.geodesy, offset: .init(east: east, north: north)).value
        case let .degrees(latitude, longitude):
            try LocationAngularMapping.inverse(
                origin: origin.geodesy, offset: .init(latitude: latitude, longitude: longitude))
        }
        guard let coordinate = LocationCoordinate(
            latitudeDegrees: point.latitude, longitudeDegrees: point.longitude)
        else { throw LocationRecordingError.invalidCoordinate }
        return coordinate
    }

    static func encode(
        _ coordinate: LocationCoordinate,
        relativeTo origin: LocationCoordinate,
        format: LocationCoordinateFormat) throws -> Self
    {
        switch format {
        case .meters:
            let offset = try LocationGeodesy.forward(origin: origin.geodesy, point: coordinate.geodesy).value
            guard let value = Self(normalizing: .meters(eastMeters: offset.east, northMeters: offset.north))
            else { throw LocationRecordingError.invalidCoordinate }
            return value
        case .degrees:
            let offset = try LocationAngularMapping.forward(origin: origin.geodesy, point: coordinate.geodesy)
            guard let value = Self(normalizing: .degrees(
                latitudeDegrees: offset.latitude, longitudeDegrees: offset.longitude))
            else { throw LocationRecordingError.invalidCoordinate }
            return value
        }
    }
}

/// Whole-origin editing retains all existing offsets verbatim.
struct LocationHorizontalSpace: Equatable, Sendable {
    let format: LocationCoordinateFormat
    let origin: OverridableValue<LocationCoordinate>

    func relocated(to replacement: LocationCoordinate) -> Self {
        .init(format: format, origin: .override(replacement))
    }

    func coordinate(for offset: LocationHorizontalOffset) throws -> LocationCoordinate {
        guard offset.format == format else { throw LocationRecordingError.mixedCoordinateFormats }
        return try offset.coordinate(relativeTo: origin.value)
    }
}
