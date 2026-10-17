import CoreLocation
import DioramaCore
import Foundation

/// Converts already normalized semantic measurements at the native boundary.
struct LocationNativeMaterializer: Sendable {
    let fidelity: LocationFidelityOptions
    let reporter: DiagnosticReporter
    let context: DiagnosticContext

    func materialize(_ measurement: LocationMeasurement) -> CLLocation {
        let native = Self.native(measurement)
        guard fidelity.preserveEllipsoidalAltitude || (fidelity.preserveFloor && measurement.floorLevel != nil) else {
            return native
        }
        return FidelityLocation(
            backing: native,
            ellipsoidalAltitude: fidelity.preserveEllipsoidalAltitude
                ? measurement.vertical?.ellipsoidalAltitudeMeters : nil,
            floor: fidelity.preserveFloor ? measurement.floorLevel.map(FidelityFloor.init) : nil,
            sourceInformation: measurement.sourceInformation,
            reporter: reporter, context: context)
    }

    private static func native(_ measurement: LocationMeasurement) -> CLLocation {
        let coordinate = measurement.coordinate
        let altitude = measurement.vertical?.orthometricAltitudeMeters ?? 0
        let verticalAccuracy = measurement.vertical?.accuracyMeters ?? -1
        let course = measurement.course?.degrees ?? -1
        let courseAccuracy = measurement.course?.accuracyDegrees ?? -1
        let speed = measurement.speed?.metersPerSecond ?? -1
        let speedAccuracy = measurement.speed?.accuracyMetersPerSecond ?? -1
        if let source = measurement.sourceInformation {
            return CLLocation(
                coordinate: coordinate, altitude: altitude,
                horizontalAccuracy: measurement.horizontalAccuracyMeters,
                verticalAccuracy: verticalAccuracy, course: course, courseAccuracy: courseAccuracy,
                speed: speed, speedAccuracy: speedAccuracy, timestamp: measurement.timestamp,
                sourceInfo: CLLocationSourceInformation(
                    softwareSimulationState: source.simulatedBySoftware,
                    andExternalAccessoryState: source.producedByAccessory))
        }
        return CLLocation(
            coordinate: coordinate, altitude: altitude,
            horizontalAccuracy: measurement.horizontalAccuracyMeters,
            verticalAccuracy: verticalAccuracy, course: course, courseAccuracy: courseAccuracy,
            speed: speed, speedAccuracy: speedAccuracy, timestamp: measurement.timestamp)
    }
}

/// Core Location declares these immutable native classes @unchecked Sendable.
/// Restating the inherited conformance is required by Swift. These final
/// subclasses add only immutable scalars/native values and a synchronized,
/// Sendable reporter with safe identity metadata. They retain no execution,
/// State, callback, or live manager. Concurrent getters/copies/encoding never
/// mutate subclass state; reporter writes use its own lock.
private final class FidelityFloor: CLFloor, @unchecked Sendable {
    private let recordedLevel: Int

    init(level: Int) {
        recordedLevel = level
        super.init()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override var level: Int {
        recordedLevel
    }

    override func copy(with _: NSZone? = nil) -> Any {
        self
    }
}

private final class FidelityLocation: CLLocation, @unchecked Sendable {
    private let recordedEllipsoidalAltitude: Double?
    private let recordedFloor: CLFloor?
    private let reporter: DiagnosticReporter
    private let context: DiagnosticContext

    init(backing: CLLocation, ellipsoidalAltitude: Double?, floor: CLFloor?,
         sourceInformation: LocationSourceInformation?,
         reporter: DiagnosticReporter, context: DiagnosticContext)
    {
        recordedEllipsoidalAltitude = ellipsoidalAltitude
        recordedFloor = floor
        self.reporter = reporter
        self.context = context
        // Use semantic presence rather than the native initializer's default
        // source object so both construction paths follow the original policy.
        if let source = sourceInformation {
            super.init(
                coordinate: backing.coordinate, altitude: backing.altitude,
                horizontalAccuracy: backing.horizontalAccuracy, verticalAccuracy: backing.verticalAccuracy,
                course: backing.course, courseAccuracy: backing.courseAccuracy,
                speed: backing.speed, speedAccuracy: backing.speedAccuracy,
                timestamp: backing.timestamp,
                sourceInfo: CLLocationSourceInformation(
                    softwareSimulationState: source.simulatedBySoftware,
                    andExternalAccessoryState: source.producedByAccessory))
        } else {
            super.init(
                coordinate: backing.coordinate, altitude: backing.altitude,
                horizontalAccuracy: backing.horizontalAccuracy, verticalAccuracy: backing.verticalAccuracy,
                course: backing.course, courseAccuracy: backing.courseAccuracy,
                speed: backing.speed, speedAccuracy: backing.speedAccuracy,
                timestamp: backing.timestamp)
        }
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override var ellipsoidalAltitude: CLLocationDistance {
        recordedEllipsoidalAltitude ?? super.ellipsoidalAltitude
    }

    override var floor: CLFloor? {
        recordedFloor ?? super.floor
    }

    override var classForCoder: AnyClass {
        CLLocation.self
    }

    override func encode(with coder: NSCoder) {
        reporter.record(Diagnostic(issue: .system(DiagnosticLabel("location.archiveFidelityLoss")), context: context))
        super.encode(with: coder)
    }

    override func copy(with _: NSZone? = nil) -> Any {
        self
    }
}
