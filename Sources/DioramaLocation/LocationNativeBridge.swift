import CoreLocation
import DioramaCore
import Foundation

/// Actor-owned native lifetime. Synchronous tracked record scopes cover conversion
/// and consumer callbacks outside Core's state lock. No task outlives a callback.
@MainActor
final class LocationNativeBridge: LocationManagerBackend {
    struct Recording {
        let execution: SystemExecution<LocationCaptureState>
        let preparation: LocationNativePreparation
    }

    private var driver: any LocationNativeDriver?
    private var recording: Recording?
    private let reporter: DiagnosticReporter
    private let context: DiagnosticContext
    private let materializer: LocationNativeMaterializer
    private let now: @MainActor () -> Date
    private var locations: (@MainActor ([CLLocation]) -> Void)?
    private var failure: (@MainActor (Error) -> Void)?
    private var authorization: (@MainActor () -> Void)?
    private var trackingAccess = false
    private var active = false
    private var closed = false
    private var sessionOrigin: TimestampOrigin?
    private(set) var currentLocation: CLLocation?
    private(set) var currentState: LocationAccessState

    var isClosed: Bool {
        closed || recording?.execution.isClosed == true
    }

    init(driver: any LocationNativeDriver, recording: Recording?, reporter: DiagnosticReporter,
         context: DiagnosticContext, fidelity: LocationFidelityOptions,
         now: @escaping @MainActor () -> Date = Date.init)
    {
        self.driver = driver
        self.recording = recording
        self.reporter = reporter
        self.context = context
        self.now = now
        materializer = .init(fidelity: fidelity, reporter: reporter, context: context)
        currentState = driver.access
        currentLocation = driver.location
        if let recording {
            do {
                let state = try LocationRecordedAccessState(currentState)
                try recording.execution.state.withLock { capture, operation in
                    try operation.setHeader(on: capture.access, capturing: { state }, preparation: ValuePreparation())
                    // Even an attachment with no observer must freeze a valid empty prefix.
                    try capture.initializeAccess(operation: &operation)
                }
                if let initial = currentLocation {
                    let origin = try timestampOrigin()
                    let point = try recording.preparation.point(initial, latency: LocationNativePreparation.latency(
                        initial.timestamp, origin: origin, delivery: 0))
                    let effective = recording.preparation.policy.timestampOrigin(observed: origin)
                    recording.preparation.initial = try .init(timestampOrigin: effective, location: point)
                    currentLocation = try recording.preparation.materialize(
                        point, origin: effective, delivery: 0, using: materializer)
                }
                try updateHeader(recording)
            } catch { conversionFailed() }
        }
        driver.configure(.init())
        driver.connect(self)
    }

    func setDelivery(locations: @escaping @MainActor ([CLLocation]) -> Void,
                     failure: @escaping @MainActor (Error) -> Void)
    {
        self.locations = locations
        self.failure = failure
    }

    func observe(_ callback: @escaping @MainActor () -> Void) {
        guard !isClosed else { return }
        authorization = callback
        command { try beginAccessTracking() }
    }

    func configure(_ configuration: DioramaLocationManager.Configuration) {
        command { driver?.configure(configuration) }
    }

    func start() {
        command {
            guard !active else { return }
            if let recording {
                do {
                    let origin = try timestampOrigin()
                    try recording.execution.state.withLock { capture, operation in
                        try capture.startSession(timestampOrigin: recording.preparation.policy.timestampOrigin(
                            observed: origin), operation: &operation)
                    }
                    sessionOrigin = origin
                } catch { conversionFailed() }
            }
            active = true
            driver?.start()
        }
    }

    func stop() {
        guard !isClosed else { return }
        command {
            guard active else { return }
            if let recording {
                try recording.execution.state.withLock { capture, _ in capture.stopSession() }
            }
            active = false
            sessionOrigin = nil
            driver?.stop()
        }
    }

    func request(_ request: LocationAuthorizationRequest) {
        command {
            do {
                try beginAccessTracking()
                if let recording {
                    try recording.execution.state.withLock { capture, operation in
                        try capture.requestAuthorization(request, operation: &operation)
                    }
                }
            } catch { conversionFailed() }
            driver?.request(request)
        }
    }

    func receive(_ native: [CLLocation]) {
        callback {
            guard active else { return }
            var delivered = native
            if let recording {
                do {
                    guard let origin = sessionOrigin,
                          let token = try recording.execution.state.withLock({ capture, operation in
                              try capture.reserveSessionEvent(operation: &operation)
                          }) else { throw LocationRecordingError.invalidTrackLayout }
                    let points = try native.map { value in
                        try recording.preparation.point(value, latency: LocationNativePreparation.latency(
                            value.timestamp, origin: origin, delivery: token.deliveryMilliseconds))
                    }
                    let normalized = try points.map {
                        try recording.preparation.materialize(
                            $0, origin: token.timestampOrigin, delivery: token.deliveryMilliseconds,
                            using: materializer)
                    }
                    let prepared = try ValuePreparation<LocationCaptureEvent>().admitPrepared(.batch(points))
                    try updateHeader(recording)
                    _ = try recording.execution.state.withLock { capture, operation in
                        capture.complete(token, with: prepared, operation: &operation)
                    }
                    delivered = normalized
                } catch { conversionFailed() }
            }
            if let last = delivered.last {
                currentLocation = last
            }
            locations?(delivered)
        }
    }

    func receive(_ error: Error) {
        callback {
            guard active else { return }
            var delivered = error
            if let recording {
                do {
                    guard let token = try recording.execution.state.withLock({ capture, operation in
                        try capture.reserveSessionEvent(operation: &operation)
                    }) else { throw LocationRecordingError.invalidTrackLayout }
                    let captured = NSErrorSnapshot.capture(error as NSError)
                    for omission in captured.omissions {
                        reporter.record(Diagnostic(issue: .nativeErrorMetadataOmitted(
                            key: omission.key, runtimeType: omission.runtimeType), context: context))
                    }
                    guard let snapshot = captured.snapshot else { throw LocationRecordingError.invalidTrackLayout }
                    let prepared = try ValuePreparation<LocationCaptureEvent>().admitPrepared(.failure(snapshot))
                    _ = try recording.execution.state.withLock { capture, operation in
                        capture.complete(token, with: prepared, operation: &operation)
                    }
                    delivered = snapshot.makeError()
                } catch { conversionFailed() }
            }
            failure?(delivered)
        }
    }

    func receiveAuthorization() {
        callback {
            // Before tracking, record consumers must retain the replayable initial state.
            guard recording == nil || trackingAccess else { return }
            guard let native = driver?.access else { return }
            if let recording {
                do {
                    guard let token = try recording.execution.state.withLock({ capture, operation in
                        try capture.reserveAccessNotification(operation: &operation)
                    }) else { throw LocationRecordingError.invalidTrackLayout }
                    let prepared = try ValuePreparation<LocationRecordedAccessState>().admitPrepared(
                        LocationRecordedAccessState(native))
                    _ = try recording.execution.state.withLock { capture, operation in
                        capture.complete(token, with: prepared, operation: &operation)
                    }
                } catch { conversionFailed() }
            }
            currentState = native
            authorization?()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        driver?.connect(nil)
        driver?.stop()
        driver = nil
        recording = nil
        locations = nil
        failure = nil
        authorization = nil
        sessionOrigin = nil
    }

    private func timestampOrigin() throws -> TimestampOrigin {
        guard let origin = TimestampOrigin(date: now(), offsetMinutes: 0) else {
            throw LocationRecordingError.invalidMeasurement(position: 0)
        }
        return origin
    }

    private func beginAccessTracking() throws {
        guard !trackingAccess else { return }
        trackingAccess = true
        // The first registration or request anchors tracking, independent of construction.
        if let recording {
            try recording.execution.state.withLock { capture, operation in
                try capture.observeAccess(operation: &operation)
            }
        }
    }

    private func updateHeader(_ recording: Recording) throws {
        let header = recording.preparation.header
        try recording.execution.state.withLock { capture, operation in
            try operation.setHeader(on: capture.sessions, capturing: { header }, preparation: ValuePreparation())
        }
    }

    private func conversionFailed() {
        reporter.record(Diagnostic(issue: .conversionFailed, context: context, recordingImpact: .invalidatesCandidate))
    }

    private func command(_ body: () throws -> Void) {
        guard !isClosed else {
            reporter.record(Diagnostic(issue: .lifecycle(.leaseClosed), context: context))
            return
        }
        do {
            if let recording {
                try recording.execution.state.withTrackedValue(\.callbackScope) { _ in try body() }
            } else {
                try body()
            }
        } catch { conversionFailed() }
    }

    private func callback(_ body: () -> Void) {
        guard !isClosed else { return }
        if let recording {
            _ = try? recording.execution.state.withTrackedValueIfOpen(\.callbackScope) { _ in body() }
        } else {
            body()
        }
    }
}
