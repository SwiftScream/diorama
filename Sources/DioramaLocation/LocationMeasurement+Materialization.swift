import CoreLocation
import DioramaCore

extension LocationTracks.SessionHeader {
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
