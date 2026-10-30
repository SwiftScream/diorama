import CoreLocation
import DioramaCore

/// Main-actor delivery from a Diorama-owned location manager.
@MainActor
public protocol DioramaLocationManagerDelegate: AnyObject {
    /// Receives one recorded batch, after current location updates.
    func locationManager(_ manager: DioramaLocationManager, didUpdateLocations locations: [CLLocation])
    /// Receives a nonterminal reconstructed native error.
    func locationManager(_ manager: DioramaLocationManager, didFailWithError error: Error)
    /// Observes a complete installed authorization and service state.
    func locationManagerDidChangeAuthorization(_ manager: DioramaLocationManager)
}

public extension DioramaLocationManagerDelegate {
    /// Ignores location batches unless implemented by the delegate.
    func locationManager(_: DioramaLocationManager, didUpdateLocations _: [CLLocation]) {}
    /// Ignores nonterminal errors unless implemented by the delegate.
    func locationManager(_: DioramaLocationManager, didFailWithError _: Error) {}
    /// Ignores authorization notifications unless implemented by the delegate.
    func locationManagerDidChangeAuthorization(_: DioramaLocationManager) {}
}

/// The bounded Apple location interface. Reads never consume recorded behavior.
/// Retained managers freeze at execution finish; callbacks always run on MainActor.
@MainActor
public final class DioramaLocationManager {
    struct Configuration {
        var accuracy = kCLLocationAccuracyBest
        var filter = kCLDistanceFilterNone
        var activity = CLActivityType.other
        var pauses = true
    }

    private let backend: any LocationManagerBackend
    private let reporter: DiagnosticReporter
    private let context: DiagnosticContext
    private var configuration = Configuration()

    /// Weak recipient. Registration or the first authorization request starts tracking.
    /// Later registration preserves the timeline without repeating notifications.
    /// Registration after finish emits nothing.
    public weak var delegate: any DioramaLocationManagerDelegate? {
        didSet {
            guard delegate != nil else { return }
            backend.observe { [weak self] in
                guard let self else { return }
                delegate?.locationManagerDidChangeAuthorization(self)
            }
        }
    }

    /// Last observed availability of device location services.
    public var locationServicesEnabled: Bool {
        backend.currentState.servicesEnabled
    }

    /// Last authorization status, presented using this platform's native values.
    public var authorizationStatus: CLAuthorizationStatus {
        backend.currentState.permission
    }

    /// Last accuracy authorization.
    public var accuracyAuthorization: CLAccuracyAuthorization {
        backend.currentState.accuracy
    }

    /// Initial cached location or the last member of the latest nonempty batch.
    public var location: CLLocation? {
        backend.currentLocation
    }

    /// Local requested accuracy; configuration is neither persisted nor matched.
    public var desiredAccuracy: CLLocationAccuracy {
        get { configuration.accuracy }
        set { set(\.accuracy, to: newValue) }
    }

    /// Local requested minimum displacement in meters.
    public var distanceFilter: CLLocationDistance {
        get { configuration.filter }
        set { set(\.filter, to: newValue) }
    }

    /// Local requested activity category.
    public var activityType: CLActivityType {
        get { configuration.activity }
        set { set(\.activity, to: newValue) }
    }

    /// Local automatic-pause preference.
    public var pausesLocationUpdatesAutomatically: Bool {
        get { configuration.pauses }
        set { set(\.pauses, to: newValue) }
    }

    init(execution: SystemExecution<LocationReplayState>, fidelity: LocationFidelityOptions = .init()) throws {
        let backend = try LocationReplayBackend(execution: execution, fidelity: fidelity)
        self.backend = backend
        reporter = execution.reporter
        context = try execution.state.withLock { state, _ in .attachment(state.sessions.id.attachmentID) }
        connect()
    }

    init(backend: any LocationManagerBackend, reporter: DiagnosticReporter, context: DiagnosticContext) {
        self.backend = backend
        self.reporter = reporter
        self.context = context
        connect()
    }

    private func connect() {
        backend.setDelivery(locations: { [weak self] locations in
            guard let self else { return }
            delegate?.locationManager(self, didUpdateLocations: locations)
        }, failure: { [weak self] error in
            guard let self else { return }
            delegate?.locationManager(self, didFailWithError: error)
        })
    }

    /// Selects the next session once; repeated active starts are idempotent.
    public func startUpdatingLocation() {
        backend.start()
    }

    /// Stops the current session. Repeated and post-finish stops do nothing.
    public func stopUpdatingLocation() {
        backend.stop()
    }

    /// Starts access tracking if needed, then releases only the next matching when-in-use barrier.
    public func requestWhenInUseAuthorization() {
        backend.request(.whenInUse)
    }

    /// Starts access tracking if needed, then releases only the next matching always barrier.
    public func requestAlwaysAuthorization() {
        backend.request(.always)
    }

    /// Core's stop hook closes both timelines before awaiting scheduler drainage.
    func close() {
        backend.close()
    }

    private func set<Value>(_ keyPath: WritableKeyPath<Configuration, Value>, to value: Value) {
        guard !backend.isClosed else {
            reporter.record(Diagnostic(issue: .lifecycle(.leaseClosed), context: context))
            return
        }
        configuration[keyPath: keyPath] = value
        backend.configure(configuration)
    }
}
