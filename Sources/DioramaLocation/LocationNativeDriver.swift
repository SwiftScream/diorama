import CoreLocation

/// Only the owned manager crosses this test seam; consumer managers are never mutated.
@MainActor
protocol LocationNativeDriver: AnyObject {
    var location: CLLocation? { get }
    var access: LocationAccessState { get }
    func connect(_ bridge: LocationNativeBridge?)
    func configure(_ configuration: DioramaLocationManager.Configuration)
    func start()
    func stop()
    func request(_ request: LocationAuthorizationRequest)
}

@MainActor
final class CoreLocationDriver: NSObject, LocationNativeDriver, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private weak var bridge: LocationNativeBridge?

    var location: CLLocation? {
        manager.location
    }

    var access: LocationAccessState {
        .init(servicesEnabled: CLLocationManager.locationServicesEnabled(),
              permission: manager.authorizationStatus, accuracy: manager.accuracyAuthorization)
    }

    func connect(_ bridge: LocationNativeBridge?) {
        self.bridge = bridge
        manager.delegate = bridge == nil ? nil : self
    }

    func configure(_ configuration: DioramaLocationManager.Configuration) {
        manager.desiredAccuracy = configuration.accuracy
        manager.distanceFilter = configuration.filter
        manager.activityType = configuration.activity
        manager.pausesLocationUpdatesAutomatically = configuration.pauses
    }

    func start() {
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func request(_ request: LocationAuthorizationRequest) {
        switch request {
        case .whenInUse: manager.requestWhenInUseAuthorization()
        case .always: manager.requestAlwaysAuthorization()
        }
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        bridge?.receive(locations)
    }

    func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        bridge?.receive(error)
    }

    func locationManagerDidChangeAuthorization(_: CLLocationManager) {
        bridge?.receiveAuthorization()
    }
}
