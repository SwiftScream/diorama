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
/// Record-mode observations form a new ordered working sequence; replay claims
/// the immutable prepared baseline. Passthrough retains neither content set.
public final class SequentialTrackLease<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var baseline: [SequentialRecord<Value>]
        var recording: [SequentialRecord<Value>?] = []
        var nextReplayPosition = 0
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
        state = Mutex(State(baseline: track.records))
    }

    /// Whether startup rollback or explicit finish has closed this lease.
    public var isClosed: Bool {
        admission.isClosed || state.withLock { $0.closed }
    }

    /// Reserves an ordered position, prepares an observation, and admits it.
    ///
    /// Reservation occurs atomically before `capture` and the preparation
    /// policy run, so slower work cannot reorder observations. Failed or
    /// closed admission leaves its reserved sequence unavailable for reuse.
    /// Capture, preparation, reporting, and sink notification run outside the
    /// lease lock. This operation is available only in record mode.
    ///
    /// - Parameters:
    ///   - capture: Stable extraction or conversion at the caller's boundary.
    ///   - preparation: The immutable setup policy owned by the system.
    ///   - fieldPath: Safe setup-authored semantic field labels.
    ///   - rule: A safe setup-authored preparation-policy identifier.
    /// - Returns: The stable identity reserved at observation time.
    /// - Throws: Safe, already-reported operation or preparation evidence.
    @discardableResult
    public func append(
        capturing capture: () throws -> Value,
        preparation: ValuePreparation<Value>,
        fieldPath: [DiagnosticLabel] = [],
        rule: DiagnosticLabel? = nil) throws(SequentialOperationFailure) -> RecordIdentity
    {
        let result: Result<(index: Int, identity: RecordIdentity), SequentialOperationFailure> =
            state.withLock { state in
                if let failure = closedFailure(state) {
                    return .failure(failure)
                }
                guard mode == .record else {
                    return .failure(operationFailure(
                        .wrongMode(expected: .record, actual: mode),
                        context: .track(id)))
                }
                let index = state.recording.endIndex
                let identity = RecordIdentity(trackID: id, sequence: UInt64(index))
                state.recording.append(nil)
                return .success((index, identity))
            }
        let reservation: (index: Int, identity: RecordIdentity)
        switch result {
        case let .success(value):
            reservation = value
        case let .failure(failure):
            reporter.record(failure.diagnostic)
            throw failure
        }

        let prepared: PreparedValue<Value>
        do {
            prepared = try preparation.prepare(
                capturing: capture,
                purpose: .recording,
                reporter: reporter,
                context: .record(reservation.identity),
                fieldPath: fieldPath,
                rule: rule)
        } catch {
            throw SequentialOperationFailure(diagnostic: error.diagnostic)
        }

        let admitted = state.withLock { state in
            guard !admission.isClosed, !state.closed else { return false }
            state.recording[reservation.index] = SequentialRecord(
                identity: reservation.identity,
                value: prepared.value)
            return true
        }
        guard admitted else {
            let failure = operationFailure(.leaseClosed, context: .record(reservation.identity))
            reporter.record(failure.diagnostic)
            throw failure
        }
        return reservation.identity
    }

    /// Atomically claims and returns the next record exactly once.
    ///
    /// Each request receives a stable position, including requests after
    /// exhaustion. A claimed record never becomes available again. This
    /// operation is available only in replay mode and never consults a live
    /// dependency.
    ///
    /// - Returns: The next stable record in this track.
    /// - Throws: Safe, already-reported closed, wrong-mode, or exhaustion evidence.
    public func claimNext() throws(SequentialOperationFailure) -> SequentialRecord<Value> {
        let result: Result<SequentialRecord<Value>, SequentialOperationFailure> = state.withLock { state in
            if let failure = closedFailure(state) {
                return .failure(failure)
            }
            guard mode == .replay else {
                return .failure(operationFailure(
                    .wrongMode(expected: .replay, actual: mode),
                    context: .track(id)))
            }
            let requested = state.nextReplayPosition
            state.nextReplayPosition += 1
            guard requested < state.baseline.count else {
                let identity = RecordIdentity(trackID: id, sequence: UInt64(requested))
                return .failure(operationFailure(
                    .replayExhausted(availableCount: UInt64(state.baseline.count)),
                    context: .record(identity)))
            }
            return .success(state.baseline[requested])
        }
        switch result {
        case let .success(record):
            return record
        case let .failure(failure):
            reporter.record(failure.diagnostic)
            throw failure
        }
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

    func baselineRecords() -> [SequentialRecord<Value>] {
        state.withLock { $0.baseline }
    }

    func recordedRecords() -> [SequentialRecord<Value>] {
        state.withLock { $0.recording.compactMap(\.self) }
    }

    private func closedFailure(_ state: State) -> SequentialOperationFailure? {
        if admission.isClosed || state.closed {
            operationFailure(.leaseClosed, context: .track(id))
        } else {
            nil
        }
    }

    private func operationFailure(
        _ issue: SequentialOperationIssue,
        context: DiagnosticContext) -> SequentialOperationFailure
    {
        SequentialOperationFailure(diagnostic: Diagnostic(issue: .sequential(issue), context: context))
    }

    private func operationFailure(
        _ issue: ScenarioLifecycleIssue,
        context: DiagnosticContext) -> SequentialOperationFailure
    {
        SequentialOperationFailure(diagnostic: Diagnostic(issue: .lifecycle(issue), context: context))
    }
}

extension SequentialTrackLease: AnySequentialLease {
    func close() {
        // Release stable values outside the lock: their destruction may run
        // consumer code. The closed lease never retains the detached content.
        let detached = state.withLock { state in
            state.closed = true
            let records = state.baseline + state.recording.compactMap(\.self)
            state.baseline = []
            state.recording = []
            return records
        }
        withExtendedLifetime(detached) {}
    }
}

/// Safe evidence for a failed typed sequential-track operation.
public struct SequentialOperationFailure: Error, Equatable, Sendable {
    /// The diagnostic retained before this failure was returned.
    public let diagnostic: Diagnostic
}
