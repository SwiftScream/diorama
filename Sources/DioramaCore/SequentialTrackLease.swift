import Synchronization

/// A small shared closure bit, never a reference back to execution resources.
final class ExecutionAdmission: Sendable {
    private let closed = Mutex(false)
    var isClosed: Bool {
        closed.withLock { $0 }
    }

    func close() {
        closed.withLock { $0 = true }
    }
}

protocol AnySequentialLease: Sendable {
    var id: TrackID { get }
    func close()
}

/// A reference-semantic, execution-owned lifetime for one typed track.
///
/// References share one lifetime within a run; different starts get fresh
/// leases. After closure, only identity, mode, and reporting context remain.
/// Ordered record append and replay claim operations belong to the subsequent
/// sequential-operations slice, not this lifetime boundary.
public final class SequentialTrackLease<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var records: [SequentialRecord<Value>]
        var closed = false
    }

    /// The stable identity of this track.
    public let id: TrackID
    /// The effective whole-attachment mode for this run.
    public let mode: ScenarioMode
    /// Lightweight reporting context that may safely outlive the execution.
    public let reporter: DiagnosticReporter

    private let state: Mutex<State>
    private let admission: ExecutionAdmission

    init(track: SequentialTrack<Value>, mode: ScenarioMode,
         reporter: DiagnosticReporter, admission: ExecutionAdmission)
    {
        id = track.id
        self.mode = mode
        self.reporter = reporter
        self.admission = admission
        state = Mutex(State(records: track.records))
    }

    /// Whether startup rollback or explicit finish has closed this lease.
    public var isClosed: Bool {
        admission.isClosed || state.withLock { $0.closed }
    }

    /// Reports a system fact while this lease remains open.
    ///
    /// Closed use instead reports a distinct lifecycle fact and does not
    /// change the frozen final result. Notification occurs outside lease locks.
    /// A notification racing finish follows the reporter's freeze boundary.
    ///
    /// - Parameters:
    ///   - issue: A safe infrastructure fact, not a dependency error payload.
    ///   - recordingImpact: Its effect on candidate health while open.
    /// - Returns: Whether the lease accepted the system fact before closure.
    public func report(_ issue: DiagnosticIssue, recordingImpact: RecordingImpact = .none) -> Bool {
        let open = !isClosed
        reporter.record(Diagnostic(
            issue: open ? issue : .lifecycle(.leaseClosed),
            context: .track(id),
            recordingImpact: open ? recordingImpact : .none))
        return open
    }
}

extension SequentialTrackLease: AnySequentialLease {
    func close() {
        // Release stable values outside the lock: their destruction may run
        // consumer code. The closed lease never retains the detached content.
        let detached = state.withLock { state in
            state.closed = true
            let records = state.records
            state.records = []
            return records
        }
        withExtendedLifetime(detached) {}
    }
}
