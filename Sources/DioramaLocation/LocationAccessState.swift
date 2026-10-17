import CoreLocation

/// One complete location-access observation for recording and replay.
struct LocationAccessState: Equatable, Sendable {
    let servicesEnabled: Bool
    let permission: CLAuthorizationStatus
    let accuracy: CLAccuracyAuthorization
}

extension LocationAccessState {
    /// Native presentation does not change persisted permission or request identity.
    init(_ recorded: LocationRecordedAccessState) {
        servicesEnabled = recorded.servicesEnabled
        switch recorded.permission {
        case .notDetermined: permission = .notDetermined
        case .restricted: permission = .restricted
        case .denied: permission = .denied
        case .always: permission = .authorizedAlways
        case .whenInUse:
            #if os(macOS)
                permission = .authorizedAlways
            #else
                permission = .authorizedWhenInUse
            #endif
        }
        switch recorded.accuracy {
        case .full: accuracy = .fullAccuracy
        case .reduced: accuracy = .reducedAccuracy
        }
    }
}
