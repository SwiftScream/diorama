import Synchronization

private final class CaptureOwner: Sendable {}

/// One runtime-only monotonic observation in a scenario execution.
///
/// Captures preserve their observation order even when later conversion work
/// completes out of order. They are not stable scenario values or persistence
/// data, and cannot be created outside an execution's time service.
public struct LogicalTimeCapture: Sendable {
    fileprivate let owner: CaptureOwner
    fileprivate let order: UInt64
    fileprivate let time: Duration
}

/// Safe failures from an execution's logical-time service.
public enum ExecutionTimeIssue: Error, Equatable, Sendable {
    /// Startup has not completed, so the execution has no time origin yet.
    case notStarted
    /// Execution admission has closed.
    case executionClosed
    /// The injected or host monotonic source moved backward.
    case clockMovedBackward
    /// Captures from different executions cannot be combined.
    case foreignCapture
    /// A later capture was supplied as the beginning of an interval.
    case reversedCaptures
    /// A requested logical delay is negative.
    case negativeDelay
    /// A logical duration or capture order cannot be represented.
    case overflow
}

/// A safe logical-time failure retained by the diagnostic reporter.
public struct ExecutionTimeFailure: Error, Equatable, Sendable {
    /// The reported fact, without any host clock instant.
    public let diagnostic: Diagnostic
}

/// Execution-owned logical time and monotonic observation capture.
///
/// The origin starts only after every system activates. Systems can retain this
/// service from their preparation context, then capture during live operation.
/// Every attachment in one execution receives the same service and rate. Host
/// instants remain private, and capture tokens have no stable encoding.
public final class ExecutionTime: Sendable {
    private struct State: Sendable {
        var clock: ExecutionClock?
        var origin: ContinuousClock.Instant?
        var lastRead: ContinuousClock.Instant?
        var nextOrder: UInt64 = 0
    }

    private let state: Mutex<State>
    private let admission: ExecutionAdmission
    private let reporter: DiagnosticReporter
    private let owner = CaptureOwner()

    init(clock: ExecutionClock,
         admission: ExecutionAdmission, reporter: DiagnosticReporter)
    {
        state = Mutex(State(clock: clock))
        self.admission = admission
        self.reporter = reporter
    }

    func start() {
        state.withLock { state in
            guard state.origin == nil, let clock = state.clock else {
                preconditionFailure("Logical time can start only once")
            }
            let origin = clock.now()
            state.origin = origin
            state.lastRead = origin
        }
    }

    func close() {
        // Drop an injected source outside the lock; its captured values can
        // run arbitrary destruction code.
        let source = state.withLock { state in
            let source = state.clock
            state.clock = nil
            state.origin = nil
            state.lastRead = nil
            return source
        }
        withExtendedLifetime(source) {}
    }

    /// Returns the duration since this execution completed startup.
    ///
    /// Reads are serialized with captures. An active execution's logical time
    /// never decreases, even when callers read concurrently.
    public func logicalNow() throws(ExecutionTimeFailure) -> Duration {
        switch read(reservingCapture: false) {
        case let .success(value): value.time
        case let .failure(issue): throw failure(issue)
        }
    }

    /// Reserves observation order and monotonic time before conversion work.
    ///
    /// Call this at the native observation boundary. Keep the token within the
    /// system's runtime state, then use it to derive meaningful relative timing
    /// after stable conversion. Capturing never adds timing to a track itself.
    public func capture() throws(ExecutionTimeFailure) -> LogicalTimeCapture {
        switch read(reservingCapture: true) {
        case let .success(value):
            return LogicalTimeCapture(owner: owner, order: value.order!, time: value.time)
        case let .failure(issue): throw failure(issue)
        }
    }

    /// Returns a capture's logical time, rejecting another execution's token.
    public func logicalTime(at capture: LogicalTimeCapture) throws(ExecutionTimeFailure) -> Duration {
        guard capture.owner === owner else { throw failure(.foreignCapture) }
        return capture.time
    }

    /// Returns whether the first observation preceded the second.
    ///
    /// This execution-local order does not imply a persisted cross-track order.
    public func capturedBefore(_ first: LogicalTimeCapture, _ second: LogicalTimeCapture)
        throws(ExecutionTimeFailure) -> Bool
    {
        guard first.owner === owner, second.owner === owner else { throw failure(.foreignCapture) }
        return first.order < second.order
    }

    /// Returns the nonnegative elapsed time between two ordered observations.
    public func elapsed(from first: LogicalTimeCapture, to second: LogicalTimeCapture)
        throws(ExecutionTimeFailure) -> Duration
    {
        guard first.owner === owner, second.owner === owner else { throw failure(.foreignCapture) }
        guard first.order <= second.order else { throw failure(.reversedCaptures) }
        guard let result = second.time.checkedElapsed(since: first.time)
        else { throw failure(.overflow) }
        return result
    }

    /// Adds a nonnegative logical delay to a captured anchor with overflow checking.
    ///
    /// This computes a logical time only; it does not register scheduler work.
    public func logicalTime(after delay: Duration, from anchor: LogicalTimeCapture)
        throws(ExecutionTimeFailure) -> Duration
    {
        guard anchor.owner === owner else { throw failure(.foreignCapture) }
        guard delay >= .zero else { throw failure(.negativeDelay) }
        guard let result = anchor.time.checkedLogicalTime(adding: delay)
        else { throw failure(.overflow) }
        return result
    }

    /// Gives the deadline engine a checked clock snapshot with a scheduling
    /// issue. The engine reports that issue after releasing its own state lock.
    func schedulingSnapshot() -> Result<ExecutionTimeReading, SchedulingIssue> {
        read(reservingCapture: false).mapError { .logicalTime($0) }
    }

    private func read(reservingCapture: Bool) -> Result<ExecutionTimeReading, ExecutionTimeIssue> {
        state.withLock { state in
            guard !admission.isClosed else { return .failure(.executionClosed) }
            guard let origin = state.origin, let clock = state.clock,
                  let lastRead = state.lastRead else { return .failure(.notStarted) }
            if reservingCapture, state.nextOrder == UInt64.max {
                return .failure(.overflow)
            }
            let instant = clock.now()
            guard instant >= lastRead else { return .failure(.clockMovedBackward) }
            let time = origin.duration(to: instant)
            guard time >= .zero else { return .failure(.clockMovedBackward) }
            state.lastRead = instant
            if reservingCapture {
                let order = state.nextOrder
                state.nextOrder += 1
                return .success(ExecutionTimeReading(time: time, order: order, origin: origin, clock: clock))
            }
            return .success(ExecutionTimeReading(time: time, order: nil, origin: origin, clock: clock))
        }
    }

    private func failure(_ issue: ExecutionTimeIssue) -> ExecutionTimeFailure {
        let diagnostic = Diagnostic(issue: .logicalTime(issue))
        reporter.record(diagnostic)
        return ExecutionTimeFailure(diagnostic: diagnostic)
    }
}
