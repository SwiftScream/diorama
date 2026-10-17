import CoreLocation

/// One complete location-access observation for recording and replay.
struct LocationAccessState: Equatable, Sendable {
    let servicesEnabled: Bool
    let permission: CLAuthorizationStatus
    let accuracy: CLAccuracyAuthorization
}
