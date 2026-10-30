import CoreLocation
import DioramaCore
import Foundation

/// One attachment's update replay. G07 connects this directly to its weak delegate.
/// The scheduler owns every delivery scope; no sequence or unstructured task is used.
@MainActor
final class LocationUpdateReplay {
    private struct Session {
        let claim: ReplayClaim<LocationSession>
        let anchor: LogicalTimeCapture
        var nextEvent = 0
        var deliveryMilliseconds: Int64 = 0
    }

    private enum Phase {
        case inactive
        case active(Session)
        case inert
    }

    private struct Runtime {
        let execution: SystemExecution<LocationReplayState>
        let header: LocationTracks.SessionHeader
        var phase: Phase = .inactive
        var pending: ScheduledItemHandle?
    }

    private var runtime: Runtime?
    private let fidelity: LocationFidelityOptions
    private let reporter: DiagnosticReporter
    private let context: DiagnosticContext
    private var locations: (@MainActor @Sendable ([CLLocation]) -> Void)?
    private var failure: (@MainActor @Sendable (Error) -> Void)?

    /// Last normalized location, readable without claiming or consuming a record.
    private(set) var currentLocation: CLLocation?

    var isActive: Bool {
        guard let runtime else { return false }
        if case .inactive = runtime.phase {
            return false
        }
        return true
    }

    var isClosed: Bool {
        runtime?.execution.isClosed ?? true
    }

    init(execution: SystemExecution<LocationReplayState>, fidelity: LocationFidelityOptions = .init()) throws {
        let (header, attachmentID) = try execution.state.withLock { state, operation in
            try (operation.replayHeader(on: state.sessions), state.sessions.id.attachmentID)
        }
        runtime = Runtime(execution: execution, header: header)
        self.fidelity = fidelity
        reporter = execution.reporter
        context = .attachment(attachmentID)
        if let initial = header.initial {
            currentLocation = try LocationNativeMaterializer(
                fidelity: fidelity, reporter: reporter, context: context)
                .materialize(initial.location.measurement(
                    coordinateSpace: header.coordinateSpace, altitudeOrigin: header.altitudeOrigin,
                    timestampOrigin: initial.timestampOrigin, deliveryMilliseconds: 0))
        }
    }

    /// Delivery closures must call consumers synchronously on MainActor. Do not
    /// wait for this execution's finish or launch work that requires its lifetime.
    func setDelivery(locations: @escaping @MainActor @Sendable ([CLLocation]) -> Void,
                     failure: @escaping @MainActor @Sendable (Error) -> Void)
    {
        guard runtime != nil else { return }
        self.locations = locations
        self.failure = failure
    }

    func start() {
        guard var runtime else {
            reporter.record(Diagnostic(issue: .lifecycle(.leaseClosed), context: context))
            return
        }
        guard case .inactive = runtime.phase else { return }
        do {
            let anchor = try runtime.execution.time.capture()
            let claim = try runtime.execution.state.withLock { state, operation in
                try operation.claim(on: state.sessions, matching: (), using: .sequential())
            }
            runtime.phase = .active(Session(claim: claim, anchor: anchor))
            self.runtime = runtime
            scheduleNext()
        } catch {
            // Core retains time/claim failures. Nonthrowing start remains inert
            // until stop, without native failure delivery or live fallback.
            runtime.phase = .inert
            self.runtime = runtime
        }
    }

    func stop() {
        guard var runtime else { return }
        let pending = runtime.pending
        runtime.pending = nil
        runtime.phase = .inactive
        self.runtime = runtime
        pending?.cancel()
    }

    /// Invoke from requestStop, before Core joins scheduler delivery. Mark closed
    /// before releasing handles/callback captures, which may reenter this object.
    func close() {
        let pending = runtime?.pending
        runtime = nil
        pending?.cancel()
        locations = nil
        failure = nil
    }

    private func scheduleNext() {
        guard var runtime, case let .active(session) = runtime.phase else { return }
        let events = session.claim.record.value.events
        guard session.nextEvent < events.count else {
            session.claim.markConsumed()
            return
        }
        do {
            // A strict session validates cumulative millisecond addition. Compute
            // from the original anchor so callback lateness adds no timing drift.
            let cumulative = session.deliveryMilliseconds + events[session.nextEvent].delayMilliseconds
            let deadline = try runtime.execution.time.logicalTime(
                after: .milliseconds(cumulative), from: session.anchor)
            let identity = session.claim.record.identity
            let index = session.nextEvent
            runtime.pending = try runtime.execution.scheduling.schedule(at: deadline, for: identity) { [weak self] in
                await self?.deliver(record: identity, event: index, cumulativeMilliseconds: cumulative)
            }
            self.runtime = runtime
        } catch {
            runtime.pending = nil
            runtime.phase = .inert
            self.runtime = runtime
        }
    }

    private func deliver(record: RecordIdentity, event index: Int, cumulativeMilliseconds: Int64) {
        guard var runtime, !runtime.execution.isClosed,
              case var .active(session) = runtime.phase,
              session.claim.record.identity == record, session.nextEvent == index
        else { return }
        let event = session.claim.record.value.events[index]
        session.nextEvent += 1
        session.deliveryMilliseconds = cumulativeMilliseconds
        runtime.pending = nil
        runtime.phase = .active(session)
        self.runtime = runtime

        do {
            switch event {
            case let .batch(_, points):
                let materializer = LocationNativeMaterializer(
                    fidelity: fidelity, reporter: reporter, context: .record(record))
                let values = try points.map { point in
                    guard let origin = session.claim.record.value.timestampOrigin?.value else {
                        throw LocationRecordingError.invalidMeasurement(position: index)
                    }
                    return try materializer.materialize(point.measurement(
                        coordinateSpace: runtime.header.coordinateSpace, altitudeOrigin: runtime.header.altitudeOrigin,
                        timestampOrigin: origin, deliveryMilliseconds: cumulativeMilliseconds))
                }
                if let last = values.last {
                    currentLocation = last
                }
                session.claim.advance(to: UInt64(session.nextEvent))
                locations?(values)
            case let .failure(_, error):
                session.claim.advance(to: UInt64(session.nextEvent))
                failure?(error.makeError())
            }
        } catch {
            reporter.record(Diagnostic(issue: .conversionFailed, context: .record(record)))
            stop()
            if var runtime = self.runtime {
                runtime.phase = .inert
                self.runtime = runtime
            }
            return
        }

        // Reentrant stop/restart may already have selected another record. The
        // completed old event still counts, but must not schedule into that run.
        if session.nextEvent == session.claim.record.value.events.count {
            session.claim.markConsumed()
        }
        guard let current = self.runtime, case let .active(active) = current.phase,
              active.claim.record.identity == record, active.nextEvent == session.nextEvent
        else { return }
        scheduleNext()
    }
}
