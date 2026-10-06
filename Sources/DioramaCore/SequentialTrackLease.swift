import Foundation
import Synchronization

/// An execution-owned, reference-semantic lifetime for one typed track.
/// References share a lifetime within a run; new runs get fresh leases.
/// Recording builds a new sequence, replay claims the baseline, and
/// passthrough retains neither. Closed leases retain no track content.
public final class SequentialTrackLease<Value: Sendable, Header: Sendable>: Sendable {
    private enum HeaderSlot: Sendable {
        case empty
        case preparing(UInt64)
        case failed
        case admitted(Header)

        var value: Header? {
            if case let .admitted(header) = self {
                header
            } else {
                nil
            }
        }
    }

    private enum RecordingSlot: Sendable {
        case preparing
        case failed
        case admitted(SequentialRecord<Value>)
        case accumulating(AccumulationSlot)

        var record: SequentialRecord<Value>? {
            if case let .admitted(record) = self {
                record
            } else {
                nil
            }
        }
    }

    private struct AccumulationSlot: Sendable {
        let freeze: @Sendable () -> Value?
        let preparation: ValuePreparation<Value>
    }

    private struct ClosedContents {
        let usage: SequentialTrackUsage
        let records: [SequentialRecord<Value>]
        let baselineHeader: Header?
        let recordingHeader: Header?
        let incomplete: [RecordIdentity]
        let incompleteHeader: Bool
        let recording: SequentialTrack<Value, Header>?
    }

    private struct State: Sendable {
        var baseline: [SequentialRecord<Value>]
        var baselineHeader: Header?
        var recording: [RecordingSlot] = []
        var recordingHeader: HeaderSlot = .empty
        var nextHeaderAttempt: UInt64 = 0
        var pendingHeaderAttempts: UInt64 = 0
        var nextReplayPosition = 0
        var claimed: IndexSet = []
        var closed = false
        var finalUsage: SequentialTrackUsage?
    }

    /// The stable identity of this track.
    public let id: TrackID
    /// The effective whole-attachment mode for this run.
    public let mode: ScenarioMode
    /// Lightweight reporting context that may safely outlive the execution.
    public let reporter: DiagnosticReporter

    private let state: Mutex<State>
    private let closing = Mutex(())
    private let admission: ExecutionAdmission

    init(track: SequentialTrack<Value, Header>, baseline: [SequentialRecord<Value>],
         baselineHeader: Header?, mode: ScenarioMode,
         reporter: DiagnosticReporter, admission: ExecutionAdmission)
    {
        id = track.id
        self.mode = mode
        self.reporter = reporter
        self.admission = admission
        state = Mutex(State(baseline: baseline, baselineHeader: baselineHeader))
    }

    /// Whether startup rollback or explicit finish has closed this lease.
    public var isClosed: Bool {
        admission.isClosed || state.withLock { $0.closed }
    }

    /// Captures, prepares, and admits a complete record at an ordered position.
    ///
    /// Reservation precedes capture so slower work cannot reorder records.
    /// A failed or closed attempt cannot reuse its position. Capture,
    /// preparation, reporting, and sink notification run outside the lock.
    /// Available only in record mode. Use `beginRecord(preparation:capturing:freeze:)`
    /// when capture continues over time and the record is finalized later.
    ///
    /// - Parameters:
    ///   - capture: Stable extraction or conversion at the caller's boundary.
    ///   - preparation: The immutable setup policy owned by the system.
    ///   - fieldPath: Safe setup-authored semantic field labels.
    ///   - rule: A safe setup-authored preparation-policy identifier.
    /// - Returns: The stable identity reserved at observation time.
    /// - Throws: Safe, already-reported operation or preparation evidence.
    @discardableResult
    public func record(
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
                state.recording.append(.preparing)
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
            markRecordingFailed(at: reservation.index)
            throw SequentialOperationFailure(diagnostic: error.diagnostic)
        }

        let admitted = state.withLock { state in
            guard !admission.isClosed, !state.closed else { return false }
            state.recording[reservation.index] = .admitted(SequentialRecord(
                identity: reservation.identity,
                value: prepared.value))
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
            while state.claimed.contains(state.nextReplayPosition) {
                state.nextReplayPosition += 1
            }
            let requested = state.nextReplayPosition
            state.nextReplayPosition += 1
            guard requested < state.baseline.count else {
                let identity = RecordIdentity(trackID: id, sequence: UInt64(requested))
                return .failure(operationFailure(
                    .replayExhausted(availableCount: UInt64(state.baseline.count)),
                    context: .record(identity)))
            }
            state.claimed.insert(requested)
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
        state.withLock { $0.recording.compactMap(\.record) }
    }

    private func markRecordingFailed(at index: Int) {
        state.withLock { state in
            if !state.closed {
                state.recording[index] = .failed
            }
        }
    }

    private func closedFailure(_ state: State) -> SequentialOperationFailure? {
        guard admission.isClosed || state.closed else { return nil }
        return operationFailure(.leaseClosed, context: .track(id))
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

    private func recordingTrack(
        header: Header?, records: [SequentialRecord<Value>]) -> SequentialTrack<Value, Header>
    {
        guard let header else {
            preconditionFailure("A record-mode track must retain its header")
        }
        return SequentialTrack(id: id, header: header, preparedRecords: records)
    }
}

public extension SequentialTrackLease {
    /// Returns the validated baseline header without consuming a record.
    func baselineHeader() -> Header? {
        state.withLock { $0.baselineHeader }
    }

    /// Records a prepared header for this track's new record sequence.
    ///
    /// Independent of record positions, the latest call to begin wins.
    /// Failed preparation leaves the candidate unhealthy despite later success.
    func setHeader(
        capturing capture: () throws -> Header,
        preparation: ValuePreparation<Header>) throws(SequentialOperationFailure)
    {
        let (attempt, previous) = try reserveHeaderAttempt()
        defer { withExtendedLifetime(previous) {} }

        let prepared: PreparedValue<Header>
        do {
            prepared = try preparation.prepare(
                capturing: capture, purpose: .recording,
                reporter: reporter, context: .track(id))
        } catch {
            state.withLock { state in
                if !state.closed {
                    state.pendingHeaderAttempts -= 1
                    if case .preparing(attempt) = state.recordingHeader {
                        state.recordingHeader = .failed
                    }
                }
            }
            throw SequentialOperationFailure(diagnostic: error.diagnostic)
        }
        let admitted = state.withLock { state in
            guard !admission.isClosed, !state.closed else { return false }
            state.pendingHeaderAttempts -= 1
            if case .preparing(attempt) = state.recordingHeader {
                state.recordingHeader = .admitted(prepared.value)
            }
            return true
        }
        guard admitted else {
            let failure = operationFailure(.leaseClosed, context: .track(id))
            reporter.record(failure.diagnostic)
            throw failure
        }
    }

    private func reserveHeaderAttempt() throws(SequentialOperationFailure) -> (UInt64, HeaderSlot) {
        let reservation: Result<(UInt64, HeaderSlot), SequentialOperationFailure> = state.withLock { state in
            if let failure = closedFailure(state) {
                return .failure(failure)
            }
            guard mode == .record else {
                return .failure(operationFailure(
                    .wrongMode(expected: .record, actual: mode), context: .track(id)))
            }
            let attempt = state.nextHeaderAttempt
            state.nextHeaderAttempt += 1
            state.pendingHeaderAttempts += 1
            let previous = state.recordingHeader
            state.recordingHeader = .preparing(attempt)
            return .success((attempt, previous))
        }
        switch reservation {
        case let .success(value):
            return value
        case let .failure(failure):
            reporter.record(failure.diagnostic)
            throw failure
        }
    }
}

/// Incremental recording retains a system-owned accumulator until finalization.
public extension SequentialTrackLease {
    /// Reserves a record position before constructing its system-owned accumulator.
    ///
    /// Core does not interpret the accumulator's phases, timing, or conclusion.
    /// The factory must prepare observations before retaining them. The freeze
    /// callback must atomically stop admission, detach runtime resources, and
    /// return one complete already-prepared record, or nil on incomplete capture.
    /// An intentional open horizon must be represented by the system's value.
    /// Core validates the returned value without repeating capture transforms.
    ///
    /// Factory and freeze callbacks run outside the lease state lock. Freeze is
    /// called exactly once for each successfully constructed accumulator, including
    /// when closure races registration; in that case its result is discarded.
    /// Accumulators must synchronize their own observations against freeze and
    /// reject late calls. Callbacks must not synchronously wait for execution finish.
    /// Factory failure must clean up any resources it acquired before throwing.
    ///
    /// - Parameters:
    ///   - preparation: Validation of the complete prepared record at the horizon.
    ///   - make: Constructs a domain accumulator under the reserved record identity.
    ///   - freeze: Detaches the accumulator and supplies its strict immutable value.
    /// - Returns: The system's accumulator for ongoing capture.
    /// - Throws: Safe, already-reported mode, closure, or conversion evidence.
    func beginRecord<Accumulator: Sendable>(
        preparation: ValuePreparation<Value>,
        capturing make: (RecordIdentity) throws -> Accumulator,
        freeze: @escaping @Sendable (Accumulator) -> Value?)
        throws(SequentialOperationFailure) -> Accumulator
    {
        let reservation: Result<(Int, RecordIdentity), SequentialOperationFailure> = state.withLock { state in
            if let failure = closedFailure(state) {
                return .failure(failure)
            }
            guard mode == .record else {
                return .failure(operationFailure(.wrongMode(expected: .record, actual: mode), context: .track(id)))
            }
            let index = state.recording.endIndex
            let identity = RecordIdentity(trackID: id, sequence: UInt64(index))
            state.recording.append(.preparing)
            return .success((index, identity))
        }
        let index: Int
        let identity: RecordIdentity
        switch reservation {
        case let .success(value):
            (index, identity) = value
        case let .failure(failure):
            reporter.record(failure.diagnostic)
            throw failure
        }
        let accumulator = try createAccumulator(at: index, identity: identity, capturing: make)
        let admitted = state.withLock { state in
            guard !admission.isClosed, !state.closed else { return false }
            state.recording[index] = .accumulating(AccumulationSlot(
                freeze: { freeze(accumulator) }, preparation: preparation))
            return true
        }
        guard admitted else {
            _ = freeze(accumulator)
            let failure = operationFailure(.leaseClosed, context: .record(identity))
            reporter.record(failure.diagnostic)
            throw failure
        }
        return accumulator
    }

    private func createAccumulator<Accumulator: Sendable>(
        at index: Int,
        identity: RecordIdentity,
        capturing make: (RecordIdentity) throws -> Accumulator) throws(SequentialOperationFailure) -> Accumulator
    {
        do {
            return try make(identity)
        } catch {
            markRecordingFailed(at: index)
            if let prepared = error as? PreparationFailure,
               prepared.diagnostic.recordingImpact == .invalidatesCandidate
            {
                throw SequentialOperationFailure(diagnostic: prepared.diagnostic)
            }
            let diagnostic = Diagnostic(issue: .conversionFailed, context: .record(identity),
                                        recordingImpact: .invalidatesCandidate)
            reporter.record(diagnostic)
            throw SequentialOperationFailure(diagnostic: diagnostic)
        }
    }
}

extension SequentialTrackLease: AnySequentialLease {
    @discardableResult
    func close() -> ClosedSequentialTrack {
        closing.withLock { _ in finishClosing() }
    }

    private func freezeRecords() {
        // Admission has closed. Do not hold the state lock while an accumulator or
        // preparation policy runs; either can notify a reentrant sink.
        let accumulators = state.withLock { state in
            state.closed = true
            return state.recording.enumerated().compactMap { index, slot -> (Int, AccumulationSlot)? in
                if case let .accumulating(accumulator) = slot {
                    return (index, accumulator)
                }
                return nil
            }
        }
        for (index, accumulator) in accumulators {
            let identity = RecordIdentity(trackID: id, sequence: UInt64(index))
            let prepared: PreparedValue<Value>?
            if let value = accumulator.freeze() {
                prepared = try? accumulator.preparation.validateRecording(
                    value, reporter: reporter, context: .record(identity))
            } else {
                reporter.record(Diagnostic(issue: .verification(.recordingNotAdmitted),
                                           context: .record(identity), recordingImpact: .invalidatesCandidate))
                prepared = nil
            }
            state.withLock { state in
                state.recording[index] = prepared.map {
                    .admitted(SequentialRecord(identity: identity, value: $0.value))
                } ?? .failed
            }
        }
        withExtendedLifetime(accumulators) {}
    }

    private func finishClosing() -> ClosedSequentialTrack {
        if !state.withLock({ $0.closed }) {
            freezeRecords()
        }
        let detached = detachClosedContents()
        if detached.incompleteHeader {
            reporter.record(Diagnostic(issue: .verification(.recordingNotAdmitted), context: .track(id),
                                       recordingImpact: .invalidatesCandidate))
        }
        for identity in detached.incomplete {
            reporter.record(Diagnostic(issue: .verification(.recordingNotAdmitted), context: .record(identity),
                                       recordingImpact: .invalidatesCandidate))
        }
        withExtendedLifetime(detached) {}
        return ClosedSequentialTrack(usage: detached.usage,
                                     recording: detached.recording.map { SequentialTrackBox(track: $0) })
    }

    private func detachClosedContents() -> ClosedContents {
        state.withLock { state -> ClosedContents in
            if let usage = state.finalUsage {
                return ClosedContents(usage: usage, records: [], baselineHeader: nil, recordingHeader: nil,
                                      incomplete: [], incompleteHeader: false, recording: nil)
            }
            state.closed = true
            let incomplete = state.recording.indices.filter {
                if case .preparing = state.recording[$0] {
                    true
                } else {
                    false
                }
            }.map { RecordIdentity(trackID: id, sequence: UInt64($0)) }
            let admitted = state.recording.compactMap(\.record)
            let usage = makeUsage(state, admittedCount: admitted.count)
            state.finalUsage = usage
            let records = state.baseline + admitted
            let baselineHeader = state.baselineHeader
            let recordingHeader = state.recordingHeader.value
            let incompleteHeader = state.pendingHeaderAttempts > 0
            state.baseline = []
            state.recording = []
            state.claimed = []
            let recording = mode == .record
                ? recordingTrack(header: recordingHeader ?? baselineHeader, records: admitted)
                : nil
            state.baselineHeader = nil
            state.recordingHeader = .empty
            state.pendingHeaderAttempts = 0
            return ClosedContents(usage: usage, records: records,
                                  baselineHeader: baselineHeader, recordingHeader: recordingHeader,
                                  incomplete: incomplete, incompleteHeader: incompleteHeader,
                                  recording: recording)
        }
    }

    private func makeUsage(_ state: State, admittedCount: Int) -> SequentialTrackUsage {
        switch mode {
        case .record:
            return SequentialTrackUsage(
                id: id,
                activity: .record(recordedCount: UInt64(admittedCount),
                                  incompleteCount: UInt64(state.recording.count - admittedCount)),
                unusedRecords: [])
        case .replay:
            let unused = state.baseline.indices.filter { !state.claimed.contains($0) }
                .map { state.baseline[$0].identity }
            return SequentialTrackUsage(
                id: id, activity: .replay(usedCount: UInt64(state.claimed.count), unusedCount: UInt64(unused.count)),
                unusedRecords: unused)
        case .passthrough:
            return SequentialTrackUsage(id: id, activity: .passthrough, unusedRecords: [])
        }
    }
}
