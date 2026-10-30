import CoreLocation
import DioramaCore
import Foundation

/// Capture-local observed origins never enter tracks or diagnostics. Only the
/// effective header and normalized offsets leave this actor-owned converter.
@MainActor
final class LocationNativePreparation {
    let policy: LocationOriginPolicy
    let format: LocationCoordinateFormat
    private var observedCoordinate: LocationCoordinate?
    private var observedAltitude: LocationAltitudeOrigin?
    private(set) var coordinateSpace: LocationCoordinateSpace?
    private(set) var altitudeOrigin: LocationAltitudeOrigin?
    var initial: LocationInitialSnapshot?

    init(format: LocationCoordinateFormat, policy: LocationOriginPolicy) {
        self.format = format
        self.policy = policy
    }

    var header: LocationTracks.SessionHeader {
        .init(coordinateSpace: coordinateSpace, altitudeOrigin: altitudeOrigin, initial: initial)
    }

    func point(_ native: CLLocation, latency: Int64) throws -> LocationRecordedLocation {
        guard let measurement = LocationMeasurement(
            coordinate: native.coordinate, horizontalAccuracyMeters: native.horizontalAccuracy,
            orthometricAltitudeMeters: native.altitude, ellipsoidalAltitudeMeters: native.ellipsoidalAltitude,
            verticalAccuracyMeters: native.verticalAccuracy, floorLevel: native.floor?.level,
            speedMetersPerSecond: native.speed, speedAccuracyMetersPerSecond: native.speedAccuracy,
            courseDegrees: native.course, courseAccuracyDegrees: native.courseAccuracy,
            timestamp: native.timestamp, sourceInformation: native.sourceInformation.map {
                .init(simulatedBySoftware: $0.isSimulatedBySoftware, producedByAccessory: $0.isProducedByAccessory)
            }), let coordinate = LocationCoordinate(measurement.coordinate)
        else { throw LocationRecordingError.invalidMeasurement(position: 0) }
        if observedCoordinate == nil {
            observedCoordinate = coordinate
            coordinateSpace = policy.coordinateSpace(observed: .init(format: format, origin: .observed(coordinate)))
        }
        let offset = try LocationCoordinateOffset.encode(coordinate, relativeTo: observedCoordinate!, format: format)
        let altitude = try measurement.vertical.map { vertical -> LocationAltitudeOffset in
            if observedAltitude == nil {
                observedAltitude = LocationAltitudeOrigin(
                    meters: .observed(vertical.orthometricAltitudeMeters),
                    ellipsoidalMeters: .observed(vertical.ellipsoidalAltitudeMeters))
                altitudeOrigin = observedAltitude.map(policy.altitudeOrigin)
            }
            guard let origin = observedAltitude,
                  let offset = LocationAltitudeOffset(
                      meters: vertical.orthometricAltitudeMeters - origin.meters.value,
                      ellipsoidalMeters: vertical.ellipsoidalAltitudeMeters - origin.ellipsoidalMeters.value,
                      accuracyMeters: vertical.accuracyMeters)
            else { throw LocationRecordingError.invalidMeasurement(position: 0) }
            return offset
        }
        guard let point = LocationRecordedLocation(
            latencyMilliseconds: latency, coordinateOffset: offset,
            horizontalAccuracyMeters: measurement.horizontalAccuracyMeters, altitudeOffset: altitude,
            floor: measurement.floorLevel.map(LocationRecordedFloor.init), speed: measurement.speed,
            course: measurement.course, sourceInformation: measurement.sourceInformation)
        else { throw LocationRecordingError.invalidMeasurement(position: 0) }
        return point
    }

    func materialize(_ point: LocationRecordedLocation, origin: TimestampOrigin, delivery: Int64,
                     using materializer: LocationNativeMaterializer) throws -> CLLocation
    {
        try materializer.materialize(point.measurement(
            coordinateSpace: coordinateSpace, altitudeOrigin: altitudeOrigin,
            timestampOrigin: origin, deliveryMilliseconds: delivery))
    }

    static func latency(_ timestamp: Date, origin: TimestampOrigin, delivery: Int64) throws -> Int64 {
        guard let timestamp = StableTimeCodec.roundedToMillisecond(timestamp),
              let offset = Int64(exactly: ((timestamp.timeIntervalSince1970
                      - origin.date.timeIntervalSince1970) * 1000).rounded()),
              origin.advanced(by: offset) == timestamp
        else { throw LocationRecordingError.invalidMeasurement(position: 0) }
        let (latency, overflow) = delivery.subtractingReportingOverflow(offset)
        guard !overflow else { throw LocationRecordingError.invalidMeasurement(position: 0) }
        return latency
    }
}
