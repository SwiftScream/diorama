import CoreLocation
import DioramaCore

extension LocationRecordedLocation {
    /// Shared normalized materialization for fresh recording observations and replay.
    /// Record adapters use a fresh observed recording here, before authored override merge.
    func measurement(
        coordinateSpace: LocationCoordinateSpace?,
        altitudeOrigin: LocationAltitudeOrigin?,
        timestampOrigin: TimestampOrigin,
        deliveryMilliseconds: Int64) throws(LocationRecordingError) -> LocationMeasurement
    {
        guard let timestamp = timestamp(relativeTo: timestampOrigin, deliveryMilliseconds: deliveryMilliseconds)
        else { throw .invalidMeasurement(position: 0) }
        guard let coordinateSpace,
              let coordinate = try? coordinateSpace.coordinate(for: coordinateOffset)
        else { throw .invalidCoordinate }
        let vertical: LocationVerticalEstimate?
        if let offset = altitudeOffset {
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
            horizontalAccuracyMeters: horizontalAccuracyMeters,
            vertical: vertical,
            floorLevel: floor?.level,
            speed: speed,
            course: course,
            timestamp: timestamp,
            sourceInformation: sourceInformation)
        else { throw .invalidMeasurement(position: 0) }
        return measurement
    }
}
