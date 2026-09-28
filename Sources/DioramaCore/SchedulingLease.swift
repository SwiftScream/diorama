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
/// Handoffs run serially outside scheduler isolation, never synchronously inside
/// registration. The handoff must finish its synchronous work before returning.
/// This service does not yet track delivery dispatched onto another executor.
/// Registration order cannot guarantee resumed Swift task execution order.
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

    /// Queues a handoff at a logical offset from completed startup.
    ///
    /// A past deadline, including a negative offset, waits for the next drain.
    /// Attachment and track
    /// order come from setup; `record.sequence` supplies stable local order,
    /// including dynamic positions that need not occur in recorded content.
    public func schedule(at deadline: Duration, for record: RecordIdentity,
                         handoff: @escaping @Sendable () -> Void) throws(SchedulingFailure)
    {
        try register(.absolute(deadline), record: record, handoff: handoff)
    }

    /// Queues a handoff after a nonnegative delay from this registration.
    ///
    /// Delay addition is checked before admission. Equal deadlines use setup
    /// attachment order, setup track order, record sequence, then registration
    /// sequence. Handoffs may register more work for a subsequent drain.
    public func schedule(after delay: Duration, for record: RecordIdentity,
                         handoff: @escaping @Sendable () -> Void) throws(SchedulingFailure)
    {
        try register(.relative(delay), record: record, handoff: handoff)
    }

    private func register(_ deadline: SchedulingDeadline, record: RecordIdentity,
                          handoff: @escaping @Sendable () -> Void) throws(SchedulingFailure)
    {
        guard let trackOrder = tracks.firstIndex(of: record.trackID) else {
            throw failure(.invalidTrack, context: .attachment(attachmentID))
        }
        let order = SchedulingOrder(attachment: attachmentOrder, track: trackOrder, record: record.sequence)
        do {
            try engine.register(deadline, order: order, handoff: handoff)
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

struct SchedulingOrder: Comparable, Sendable {
    let attachment: Int
    let track: Int
    let record: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.attachment, lhs.track, lhs.record) < (rhs.attachment, rhs.track, rhs.record)
    }
}
