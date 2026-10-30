import CoreLocation
import DioramaCore
import Foundation

/// Fresh recording normalization. Baseline authored origins apply only at publication.
public struct LocationRecordingOptions: Sendable {
    let format: LocationCoordinateFormat
    let policy: LocationOriginPolicy

    /// Records regional meter offsets with fresh observed origins.
    public init() {
        format = .meters
        policy = .init()
    }

    /// Selects offset representation and optional independent origin defaults.
    /// Invalid coordinates, nonfinite heights, and unrepresentable timestamps throw.
    /// Defaults relocate normalized record delivery as well as the fresh candidate;
    /// retained authored overrides affect only the final candidate and replay.
    public init(
        coordinateFormat: LocationCoordinateFormat,
        coordinateOrigin: CLLocationCoordinate2D? = nil,
        altitudeOriginMeters: Double? = nil,
        ellipsoidalAltitudeOriginMeters: Double? = nil,
        timestampOrigin: Date? = nil) throws
    {
        let coordinate = coordinateOrigin.flatMap(LocationCoordinate.init)
        guard coordinateOrigin == nil || coordinate != nil,
              let altitude = LocationAltitudeDefaults(
                  meters: altitudeOriginMeters, ellipsoidalMeters: ellipsoidalAltitudeOriginMeters)
        else { throw LocationRecordingError.invalidCoordinate }
        let timestamp = timestampOrigin.flatMap { TimestampOrigin(date: $0, offsetMinutes: 0) }
        guard timestampOrigin == nil || timestamp != nil else {
            throw LocationRecordingError.invalidMeasurement(position: 0)
        }
        format = coordinateFormat
        policy = .init(coordinate: coordinate, altitude: altitude, timestamp: timestamp)
    }
}
