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
        case grouped(GroupingSlot)

        var record: SequentialRecord<Value>? {
            if case let .admitted(record) = self {
                record
            } else {
                nil
            }
        }
    }

    private struct GroupingSlot: Sendable {
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
        var time: ExecutionTime?
        var nextReplayPosition = 0
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
         reporter: DiagnosticReporter, admission: ExecutionAdmission, time: ExecutionTime)
    {
        id = track.id
        self.mode = mode
        self.reporter = reporter
        self.admission = admission
        state = Mutex(State(baseline: baseline, baselineHeader: baselineHeader, time: time))
    }

    /// Whether startup rollback or explicit finish has closed this lease.
    public var isClosed: Bool {
        admission.isClosed || state.withLock { $0.closed }
    }

    /// Reserves an ordered position, prepares a record, and admits it.
    ///
    /// Reservation precedes capture so slower work cannot reorder records.
    /// A failed or closed attempt cannot reuse its position. Capture,
    /// preparation, reporting, and sink notification run outside the lock.
    /// Available only in record mode.
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
        state.withLock { $0.recording.compactMap(\.record) }
    }

    private func activity(for state: State, admittedCount: Int) -> SequentialTrackUsage.Activity {
        switch mode {
        case .record:
            .record(recordedCount: UInt64(admittedCount),
                    incompleteCount: UInt64(state.recording.count - admittedCount))
        case .replay:
            .replay(usedCount: UInt64(min(state.nextReplayPosition, state.baseline.count)),
                    unusedCount: UInt64(max(state.baseline.count - state.nextReplayPosition, 0)))
        case .passthrough:
            .passthrough
        }
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

/// Grouped lifecycle recording uses the same typed sequential track and
/// reservation order as other record-mode observations.
public extension SequentialTrackLease {
    /// Reserves an interaction before capturing its stable input.
    ///
    /// Capture `beganAt` at the native observation boundary. The returned
    /// accumulator may receive correlated phases while other groups proceed.
    /// At finish, an unterminated group becomes explicitly open. The complete
    /// immutable group passes through the supplied preparation policy.
    func beginInteraction<Input: Sendable, Observation: Sendable, Decision: Sendable,
        Output: Sendable, Failure: Sendable>(
        at beganAt: LogicalTimeCapture,
        preparation: ValuePreparation<Value>,
        capturing input: () throws -> PreparedValue<Input>)
        throws(SequentialOperationFailure) -> InteractionAccumulator<Input, Observation, Decision, Output, Failure>
        where Value == InteractionRecording<Input, Observation, Decision, Output, Failure>
    {
        try registerGroup(capturing: { identity, time in
            try InteractionAccumulator(identity: identity, input: input(), beganAt: beganAt,
                                       time: time, reporter: reporter)
        }, preparation: preparation, freeze: { $0.freeze() })
    }

    /// Reserves a subscription before capturing its stable input.
    ///
    /// Deliveries and nonterminal failures retain their relative timing and
    /// order. An active subscription becomes explicitly open at finish.
    func beginSubscription<Input: Sendable, Element: Sendable, Failure: Sendable>(
        at beganAt: LogicalTimeCapture,
        preparation: ValuePreparation<Value>,
        capturing input: () throws -> PreparedValue<Input>)
        throws(SequentialOperationFailure) -> SubscriptionAccumulator<Input, Element, Failure>
        where Value == SubscriptionRecording<Input, Element, Failure>
    {
        try registerGroup(capturing: { identity, time in
            try SubscriptionAccumulator(identity: identity, input: input(), beganAt: beganAt,
                                        time: time, reporter: reporter)
        }, preparation: preparation, freeze: { $0.freeze() })
    }
}

/// Keep reservation and finalization beside the lease state so their helpers stay private.
private extension SequentialTrackLease {
    /// Reserves the group's track position before its input capture or conversion.
    /// The concrete interaction or subscription builder supplies its strict
    /// immutable value only when the execution reaches its recording horizon.
    func registerGroup<Group: Sendable>(
        capturing make: (RecordIdentity, ExecutionTime) throws -> Group,
        preparation: ValuePreparation<Value>,
        freeze: @escaping @Sendable (Group) -> Value?) throws(SequentialOperationFailure) -> Group
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
        let group = try createGroup(at: index, identity: identity, capturing: make)
        let admitted = state.withLock { state in
            guard !admission.isClosed, !state.closed else { return false }
            state.recording[index] = .grouped(GroupingSlot(freeze: { freeze(group) }, preparation: preparation))
            return true
        }
        guard admitted else {
            let failure = operationFailure(.leaseClosed, context: .record(identity))
            reporter.record(failure.diagnostic)
            throw failure
        }
        return group
    }

    private func createGroup<Group: Sendable>(
        at index: Int,
        identity: RecordIdentity,
        capturing make: (RecordIdentity, ExecutionTime) throws -> Group) throws(SequentialOperationFailure) -> Group
    {
        do {
            guard let time = state.withLock({ $0.time }) else { throw ExecutionTimeIssue.executionClosed }
            return try make(identity, time)
        } catch {
            markRecordingFailed(at: index)
            if let prepared = error as? PreparationFailure,
               prepared.diagnostic.recordingImpact == .invalidatesCandidate
            {
                throw SequentialOperationFailure(diagnostic: prepared.diagnostic)
            }
            let diagnostic = if error is ExecutionTimeFailure {
                Diagnostic(issue: .sequential(.grouped(.invalidTiming)), context: .record(identity),
                           recordingImpact: .invalidatesCandidate)
            } else {
                Diagnostic(issue: .conversionFailed, context: .record(identity),
                           recordingImpact: .invalidatesCandidate)
            }
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

    private func freezeGroups() {
        // Admission has closed. Do not hold the state lock while a group or
        // preparation policy runs; either can notify a reentrant sink.
        let groups = state.withLock { state in
            state.closed = true
            return state.recording.enumerated().compactMap { index, slot -> (Int, GroupingSlot)? in
                if case let .grouped(group) = slot {
                    return (index, group)
                }
                return nil
            }
        }
        for (index, group) in groups {
            let identity = RecordIdentity(trackID: id, sequence: UInt64(index))
            let prepared: PreparedValue<Value>?
            if let value = group.freeze() {
                prepared = try? group.preparation.validateRecording(
                    value, reporter: reporter, context: .record(identity))
            } else {
                reporter.record(Diagnostic(issue: .sequential(.grouped(.incompleteGroup)),
                                           context: .record(identity), recordingImpact: .invalidatesCandidate))
                prepared = nil
            }
            state.withLock { state in
                state.recording[index] = prepared.map {
                    .admitted(SequentialRecord(identity: identity, value: $0.value))
                } ?? .failed
            }
        }
        withExtendedLifetime(groups) {}
    }

    private func finishClosing() -> ClosedSequentialTrack {
        if !state.withLock({ $0.closed }) {
            freezeGroups()
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
            let usage = SequentialTrackUsage(id: id, activity: activity(for: state, admittedCount: admitted.count))
            state.finalUsage = usage
            let records = state.baseline + admitted
            let baselineHeader = state.baselineHeader
            let recordingHeader = state.recordingHeader.value
            let incompleteHeader = state.pendingHeaderAttempts > 0
            state.baseline = []
            state.recording = []
            state.time = nil
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
}
