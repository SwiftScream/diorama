import DioramaCore

/// Ordered access notifications and request barriers. G07 supplies delegate delivery.
@MainActor
final class LocationAccessReplay {
    private enum Selection: Sendable {
        case observation
        case request(sequence: UInt64, kind: LocationAuthorizationRequest)
    }

    private struct Segment {
        let claim: ReplayClaim<LocationTracks.AccessSegment>
        let anchor: LogicalTimeCapture
        var nextNotification = 0
        var deliveryMilliseconds: Int64 = 0

        var notifications: [LocationAccessNotification] {
            switch claim.record.value {
            case let .initial(notifications): notifications
            case let .request(segment): segment.notifications
            }
        }
    }

    private enum Phase {
        case unobserved
        case delivering(Segment)
        case barrier(sequence: UInt64)
        case inert
    }

    private struct Runtime {
        let execution: SystemExecution<LocationReplayState>
        var phase: Phase = .unobserved
        var pending: ScheduledItemHandle?
    }

    private static let rule = DiagnosticLabel("location-authorization-barrier")
    private static let selector = ReplaySelector<Selection, LocationTracks.AccessSegment>(
        rule: rule, differences: { _, _ in [DiagnosticLabel("request")] }, select: { input, records in
            let match = records.first { record in
                switch (input, record.value) {
                case (.observation, .initial):
                    record.identity.sequence == 0
                case let (.request(sequence, kind), .request(segment)):
                    record.identity.sequence == sequence && segment.request == kind
                default:
                    false
                }
            }
            return match.map { .equivalent([$0.identity]) } ?? .noMatch
        })

    private var runtime: Runtime?
    private let reporter: DiagnosticReporter
    private let context: DiagnosticContext
    private var notification: (@MainActor @Sendable () -> Void)?

    /// Complete native state, readable without claiming or consuming a record.
    private(set) var currentState: LocationAccessState

    var isClosed: Bool {
        runtime == nil
    }

    init(execution: SystemExecution<LocationReplayState>) throws {
        let (initial, trackID) = try execution.state.withLock { state, operation in
            try (operation.replayHeader(on: state.access), state.access.id)
        }
        currentState = LocationAccessState(initial)
        runtime = Runtime(execution: execution)
        reporter = execution.reporter
        context = .track(trackID)
    }

    /// First registration starts observation; replacement preserves its position.
    /// Delivery is synchronous on MainActor within the scheduler's awaited scope.
    /// A callback must not wait for this execution's finish or launch owned work.
    func observe(_ notification: @escaping @MainActor @Sendable () -> Void) {
        guard let runtime, !runtime.execution.isClosed else { return }
        self.notification = notification
        guard let current = self.runtime, case .unobserved = current.phase else { return }
        begin(.observation)
    }

    func request(_ kind: LocationAuthorizationRequest) {
        guard let runtime, !runtime.execution.isClosed else {
            reporter.record(Diagnostic(issue: .lifecycle(.leaseClosed), context: context))
            return
        }
        guard case let .barrier(sequence) = runtime.phase else {
            reporter.record(Diagnostic(
                issue: .sequential(.selection(.noMatch)), context: context,
                fieldPath: [DiagnosticLabel("request")], rule: Self.rule))
            return
        }
        begin(.request(sequence: sequence, kind: kind))
    }

    /// Call from requestStop before Core joins scheduled delivery. Clear ownership
    /// before canceling handles or releasing captures, whose destruction can reenter.
    func close() {
        let pending = runtime?.pending
        runtime = nil
        pending?.cancel()
        notification = nil
    }

    private func begin(_ selection: Selection) {
        guard var runtime else { return }
        do {
            let anchor = try runtime.execution.time.capture()
            let claim = try runtime.execution.state.withLock { state, operation in
                try operation.claim(on: state.access, matching: selection, using: Self.selector)
            }
            runtime.phase = .delivering(Segment(claim: claim, anchor: anchor))
            self.runtime = runtime
            scheduleNext()
        } catch {
            // Core retains the failure. In particular, a wrong request leaves
            // the barrier untouched so a later matching request can continue.
        }
    }

    private func scheduleNext() {
        guard var runtime, case let .delivering(segment) = runtime.phase else { return }
        guard segment.nextNotification < segment.notifications.count else {
            runtime.phase = .barrier(sequence: segment.claim.record.identity.sequence + 1)
            self.runtime = runtime
            segment.claim.markConsumed()
            return
        }
        // Finish may close admission while a consumer callback is executing.
        // Its delivered progress still counts; its remaining notifications stop.
        guard !runtime.execution.isClosed else { return }
        do {
            // Strict recording validation checks the cumulative sum. Anchor to
            // observation/request time so late delivery adds no timing drift.
            let cumulative = segment.deliveryMilliseconds
                + segment.notifications[segment.nextNotification].delayMilliseconds
            let deadline = try runtime.execution.time.logicalTime(
                after: .milliseconds(cumulative), from: segment.anchor)
            let identity = segment.claim.record.identity
            let index = segment.nextNotification
            runtime.pending = try runtime.execution.scheduling.schedule(at: deadline, for: identity) { [weak self] in
                await self?.deliver(record: identity, notification: index, cumulativeMilliseconds: cumulative)
            }
            self.runtime = runtime
        } catch {
            runtime.pending = nil
            runtime.phase = .inert
            self.runtime = runtime
        }
    }

    private func deliver(record: RecordIdentity, notification index: Int, cumulativeMilliseconds: Int64) {
        guard var runtime, !runtime.execution.isClosed,
              case var .delivering(segment) = runtime.phase,
              segment.claim.record.identity == record, segment.nextNotification == index
        else { return }
        let next = segment.notifications[index]
        segment.nextNotification += 1
        segment.deliveryMilliseconds = cumulativeMilliseconds
        let isLast = segment.nextNotification == segment.notifications.count
        runtime.pending = nil
        // The final notification reaches the next barrier before calling the
        // consumer, allowing a matching request from inside that callback.
        runtime.phase = isLast ? .barrier(sequence: record.sequence + 1) : .delivering(segment)
        self.runtime = runtime
        currentState = LocationAccessState(next.state)
        segment.claim.advance(to: UInt64(segment.nextNotification))
        notification?()

        if isLast {
            segment.claim.markConsumed()
        }
        // A callback may close observation or start another segment. Acknowledge
        // this delivery but never register work on behalf of its successor.
        guard let current = self.runtime, case let .delivering(active) = current.phase,
              active.claim.record.identity == record, active.nextNotification == segment.nextNotification
        else { return }
        scheduleNext()
    }
}
