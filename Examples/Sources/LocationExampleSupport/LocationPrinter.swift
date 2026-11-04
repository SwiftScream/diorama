import CoreLocation
import DioramaLocation

@MainActor
package final class LocationPrinter: DioramaLocationManagerDelegate {
    private let manager: DioramaLocationManager

    package init(manager: DioramaLocationManager) {
        self.manager = manager
        manager.delegate = self
    }

    package func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    package func stop() {
        manager.stopUpdatingLocation()
    }

    package func locationManager(_: DioramaLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            print("Location: \(location.coordinate.latitude), \(location.coordinate.longitude), "
                + "accuracy \(location.horizontalAccuracy)m, time \(location.timestamp)")
        }
    }

    package func locationManager(_: DioramaLocationManager, didFailWithError error: Error) {
        print("Location error: \(error)")
    }

    package func locationManagerDidChangeAuthorization(_ manager: DioramaLocationManager) {
        print("Authorization: \(manager.authorizationStatus.rawValue), "
            + "services enabled: \(manager.locationServicesEnabled)")
    }
}
