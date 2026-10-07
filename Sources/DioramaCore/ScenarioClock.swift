/// A Swift clock over one scenario execution's shared monotonic scheduler.
///
/// Obtain it from ``ScenarioExecution/context`` or ``SystemPreparationContext/clock``.
/// Reads and sleeps require no system attachment and never create recorded
/// values or usage counts. Every mode uses the same one-to-one real-time rate.
/// Finish cancels pending sleeps and freezes time at the admission-closing
/// horizon. An escaped clock retains only time state and diagnostic reporting;
/// its scheduler reference is weak.
public struct ScenarioClock: Clock, Sendable {
    private let time: ExecutionTime
    private weak var scheduler: DeadlineEngine?
    private let reporter: DiagnosticReporter

    init(time: ExecutionTime, scheduler: DeadlineEngine, reporter: DiagnosticReporter) {
        self.time = time
        self.scheduler = scheduler
        self.reporter = reporter
    }

    /// The logical duration since completed startup.
    ///
    /// After admission closes, each read diagnoses misuse and returns the
    /// frozen horizon. A failed active read diagnoses the failure and returns
    /// the last valid instant, or zero if no valid instant exists yet.
    public var now: Instant {
        Instant(offset: time.clockNow())
    }

    /// The underlying monotonic clock's resolution, retained after closure.
    public var minimumResolution: Duration {
        time.minimumResolution
    }

    /// Suspends until the scheduler claims this deadline or cancellation wins.
    ///
    /// Past deadlines enter the next scheduler drain. All tolerances, including
    /// nil, use the scheduler's stricter zero-tolerance policy. Delivery is never
    /// early, but executor load may delay resumption. Equal deadlines submit
    /// attachment work before execution sleeps; sleeps use registration order.
    /// Task resumption order is not guaranteed.
    ///
    /// Pending task cancellation or execution shutdown throws `CancellationError`.
    /// A claimed sleep completes normally even if cancellation races afterward.
    /// A new sleep after closure throws ``SchedulingFailure`` with an
    /// `executionClosed` logical-time issue, including from an already canceled
    /// task. Other scheduler failures also throw already-reported safe evidence.
    public func sleep(until deadline: Instant, tolerance _: Duration? = nil) async throws {
        guard !time.isClosed else { throw closedFailure() }
        let sleep = ClockSleep()
        try await sleep.wait { continuation in
            // Resolve the weak scheduler only for synchronous registration.
            // A suspended application task must not retain the deadline engine.
            guard let scheduler else {
                continuation.resume(throwing: closedFailure())
                return
            }
            sleep.register(continuation, until: deadline.offset, scheduler: scheduler, reporter: reporter)
        }
    }

    private func closedFailure() -> SchedulingFailure {
        let diagnostic = Diagnostic(issue: .scheduling(.logicalTime(.executionClosed)))
        reporter.record(diagnostic)
        return SchedulingFailure(diagnostic: diagnostic)
    }
}
