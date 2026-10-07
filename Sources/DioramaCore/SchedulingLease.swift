/// Safe failures from execution-owned deadline registration and waiting.
public enum SchedulingIssue: Error, Equatable, Sendable {
    /// The execution's logical-time service rejected the operation.
    case logicalTime(ExecutionTimeIssue)
    /// The requested record's track is not declared by this attachment.
    case invalidTrack
    /// The atomic registration sequence cannot represent another item.
    case registrationOverflow
    /// The internal clock failed to wait for a deadline.
    case clockWaitFailed
}

/// A scheduling failure already retained by the execution's reporter.
public struct SchedulingFailure: Error, Equatable, Sendable {
    /// Safe evidence without host instants, callback captures, or clock errors.
    public let diagnostic: Diagnostic
}

/// An attachment's execution-owned deadline registration service.
///
/// Handoffs submit delivery tasks serially outside scheduler isolation, never
/// inside registration. Completion follows the return of the awaited closure.
/// Submission order does not guarantee delivery task execution order.
public struct SchedulingLease: Sendable {
    private let engine: DeadlineEngine
    private let attachmentID: AttachmentID
    private let attachmentOrder: Int
    private let tracks: [TrackID]
    private let reporter: DiagnosticReporter

    init(engine: DeadlineEngine, attachment: ScenarioAttachment, order: Int, reporter: DiagnosticReporter) {
        self.engine = engine
        attachmentID = attachment.id
        attachmentOrder = order
        tracks = attachment.trackIDs
        self.reporter = reporter
    }

    /// Queues scoped async delivery at a logical offset from completed startup.
    ///
    /// Past deadlines, including negative offsets, wait for the next drain.
    /// Equal deadlines use setup attachment order, track order, record sequence,
    /// then registration order for task submission.
    /// The execution owns and joins the delivery task. Completion is automatic
    /// when the awaited closure returns, including early returns. Suspended
    /// delivery does not block later deadlines. Task submission follows deadline
    /// order; async body execution order is not guaranteed.
    ///
    /// Await all owned delivery work in this scope. Launching an unstructured
    /// task and returning would escape completion tracking. Awaiting this
    /// execution's finish from inside the scope would deadlock.
    @discardableResult
    public func schedule(at deadline: Duration, for record: RecordIdentity,
                         delivery: @escaping @Sendable () async -> Void)
        throws(SchedulingFailure) -> ScheduledItemHandle
    {
        try register(.absolute(deadline), record: record, delivery: delivery)
    }

    /// Queues scoped async delivery after a nonnegative delay from registration.
    ///
    /// Delay addition is checked before admission.
    /// The execution joins the complete async scope at finish. The same awaited
    /// work and ordering contract applies as for absolute-deadline delivery.
    @discardableResult
    public func schedule(after delay: Duration, for record: RecordIdentity,
                         delivery: @escaping @Sendable () async -> Void)
        throws(SchedulingFailure) -> ScheduledItemHandle
    {
        try register(.relative(delay), record: record, delivery: delivery)
    }

    private func register(_ deadline: SchedulingDeadline, record: RecordIdentity,
                          delivery: @escaping @Sendable () async -> Void)
        throws(SchedulingFailure) -> ScheduledItemHandle
    {
        guard let trackOrder = tracks.firstIndex(of: record.trackID) else {
            throw failure(.invalidTrack, context: .attachment(attachmentID))
        }
        let order = SchedulingOrder(attachment: attachmentOrder, track: trackOrder, record: record.sequence)
        do {
            return try engine.register(deadline, order: order, delivery: delivery)
        } catch {
            throw failure(error, context: .record(record))
        }
    }

    private func failure(_ issue: SchedulingIssue, context: DiagnosticContext) -> SchedulingFailure {
        let diagnostic = Diagnostic(issue: .scheduling(issue), context: context)
        reporter.record(diagnostic)
        return SchedulingFailure(diagnostic: diagnostic)
    }
}

enum SchedulingDeadline: Sendable {
    case absolute(Duration)
    case relative(Duration)

    func resolve(now: Duration) -> Result<Duration, ExecutionTimeIssue> {
        let value: Duration = switch self {
        case let .absolute(deadline): deadline
        case let .relative(delay): delay
        }
        // Check the supported logical range before decomposing an arbitrary
        // Duration; its internal representation can exceed Int64 seconds.
        guard value <= .maximumLogicalTime else { return .failure(.overflow) }
        switch self {
        case .absolute: return .success(value)
        case .relative:
            guard value >= .zero else { return .failure(.negativeDelay) }
            guard let deadline = now.checkedLogicalTime(adding: value)
            else { return .failure(.overflow) }
            return .success(deadline)
        }
    }
}

enum SchedulingOrder: Comparable, Sendable {
    case attachment(Int, track: Int, record: UInt64)
    case execution

    init(attachment: Int, track: Int, record: UInt64) {
        self = .attachment(attachment, track: track, record: record)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.attachment(left, leftTrack, leftRecord), .attachment(right, rightTrack, rightRecord)):
            (left, leftTrack, leftRecord) < (right, rightTrack, rightRecord)
        case (.attachment, .execution): true
        case (.execution, _): false
        }
    }
}
