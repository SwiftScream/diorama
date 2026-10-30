import CoreLocation
import DioramaCore

/// The facade's heterogeneous mode boundary; each backend retains its own typed state.
@MainActor
protocol LocationManagerBackend: AnyObject {
    var currentLocation: CLLocation? { get }
    var currentState: LocationAccessState { get }
    var isClosed: Bool { get }
    func observe(_ callback: @escaping @MainActor () -> Void)
    func setDelivery(locations: @escaping @MainActor ([CLLocation]) -> Void,
                     failure: @escaping @MainActor (Error) -> Void)
    func configure(_ configuration: DioramaLocationManager.Configuration)
    func start()
    func stop()
    func request(_ request: LocationAuthorizationRequest)
    func close()
}

@MainActor
final class LocationReplayBackend: LocationManagerBackend {
    private let updates: LocationUpdateReplay
    private let access: LocationAccessReplay

    init(execution: SystemExecution<LocationReplayState>, fidelity: LocationFidelityOptions) throws {
        updates = try LocationUpdateReplay(execution: execution, fidelity: fidelity)
        access = try LocationAccessReplay(execution: execution)
    }

    var currentLocation: CLLocation? {
        updates.currentLocation
    }

    var currentState: LocationAccessState {
        access.currentState
    }

    var isClosed: Bool {
        updates.isClosed
    }

    func observe(_ callback: @escaping @MainActor () -> Void) {
        access.observe(callback)
    }

    func setDelivery(locations: @escaping @MainActor ([CLLocation]) -> Void,
                     failure: @escaping @MainActor (Error) -> Void)
    {
        updates.setDelivery(locations: locations, failure: failure)
    }

    func configure(_: DioramaLocationManager.Configuration) {}
    func start() {
        updates.start()
    }

    func stop() {
        updates.stop()
    }

    func request(_ request: LocationAuthorizationRequest) {
        access.request(request)
    }

    func close() {
        updates.close(); access.close()
    }
}
