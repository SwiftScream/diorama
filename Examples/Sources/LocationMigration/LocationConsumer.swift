import CoreLocation
import DioramaLocation

/// "Migration" means adapting application code that owns a CLLocationManager to
/// accept an injected DioramaLocationManager while retaining the delegate pattern.
/// This compile-only example covers the consumer; its caller supplies the manager.
@MainActor
final class LocationConsumer: DioramaLocationManagerDelegate {
    private let manager: DioramaLocationManager
    private(set) var latest: CLLocation?
    private(set) var lastError: Error?

    init(manager: DioramaLocationManager) {
        self.manager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
    }

    func start() {
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func locationManager(_ manager: DioramaLocationManager, didUpdateLocations _: [CLLocation]) {
        latest = manager.location
    }

    func locationManager(_: DioramaLocationManager, didFailWithError error: Error) {
        lastError = error
    }
}
