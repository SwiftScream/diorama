import Foundation
import Synchronization

/// An execution-owned, reference-semantic lifetime for one typed track.
/// References share a lifetime within a run; new runs get fresh leases.
/// Recording builds a new sequence, replay claims the baseline, and
/// passthrough retains neither. Closed leases release track content and keep only
/// the continuation value explicitly requested by replay setup.
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
        var continuation: ReplayContinuationState<Value>
        var recording: [RecordingSlot] = []
        var recordingHeader: HeaderSlot = .empty
        var nextHeaderAttempt: UInt64 = 0
        var pendingHeaderAttempts: UInt64 = 0
        var nextReplayPosition = 0
        var claimed: IndexSet = []
        var replayProgress: [Int: ReplayClaimProgress] = [:]
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
         reporter: DiagnosticReporter, admission: ExecutionAdmission,
         continuationPolicy: ReplayContinuationPolicy<Value> = .error)
    {
        id = track.id
        self.mode = mode
        self.reporter = reporter
        self.admission = admission
        state = Mutex(State(baseline: baseline, baselineHeader: baselineHeader,
                            continuation: ReplayContinuationState(mode == .replay ? continuationPolicy : .error)))
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

    /// Atomically claims and consumes the next record, returning its stored value.
    ///
    /// Systems translate stored values into their domain objects. Each
    /// exhausted request receives a stable requested position and a diagnostic,
    /// but continuation never creates a record or consumption fact. Exhausted and
    /// closed replay reads follow the setup-selected continuation policy; wrong
    /// mode always throws. Diagnostic handlers run outside the lease lock.
    /// Use `claim(matching:using:)` for identity or later consumption acknowledgement.
    ///
    /// - Returns: The next stored value or the configured continuation.
    /// - Throws: Safe, already-reported wrong-mode or noncontinuable failure evidence.
    public func consumeNext() throws(SequentialOperationFailure) -> Value {
        let (result, previous) = state.withLock { state in
            // Replacing a reference-valued default must not run its destruction
            // while holding the lease lock; it may report or reenter the lease.
            let previous = state.continuation
            return (consumeNext(state: &state), previous)
        }
        defer { withExtendedLifetime(previous) {} }
        return try result.report(using: reporter)
    }

    private func consumeNext(state: inout State) -> SequentialReadResult<Value> {
        if let failure = closedFailure(state) {
            return state.continuation.resolve(failure)
        }
        guard mode == .replay else {
            return .failure(operationFailure(
                .wrongMode(expected: .replay, actual: mode), context: .track(id)))
        }
        while state.claimed.contains(state.nextReplayPosition) {
            state.nextReplayPosition += 1
        }
        let requested = state.nextReplayPosition
        state.nextReplayPosition += 1
        guard requested < state.baseline.count else {
            let identity = RecordIdentity(trackID: id, sequence: UInt64(requested))
            return state.continuation.resolve(operationFailure(
                .replayExhausted(availableCount: UInt64(state.baseline.count)),
                context: .record(identity)))
        }
        state.claimed.insert(requested)
        state.replayProgress[requested] = ReplayClaimProgress(isConsumed: true)
        let value = state.baseline[requested].value
        state.continuation.consume(value)
        return .consumed(value)
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
                return ClosedContents(usage: usage, records: [],
                                      baselineHeader: nil, recordingHeader: nil,
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
            state.replayProgress = [:]
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
                unclaimedRecords: [], claimedRecords: [])
        case .replay:
            let unused = state.baseline.indices.filter { !state.claimed.contains($0) }
                .map { state.baseline[$0].identity }
            let selected: [ReplayClaimUsage] = state.replayProgress.keys.sorted().compactMap { index in
                guard let progress = state.replayProgress[index] else { return nil }
                return ReplayClaimUsage(identity: state.baseline[index].identity,
                                        progressCount: progress.progressCount,
                                        isConsumed: progress.isConsumed)
            }
            return SequentialTrackUsage(
                id: id, activity: .replay(claimedCount: UInt64(state.claimed.count),
                                          unclaimedCount: UInt64(unused.count)),
                unclaimedRecords: unused, claimedRecords: selected)
        case .passthrough:
            return SequentialTrackUsage(id: id, activity: .passthrough, unclaimedRecords: [], claimedRecords: [])
        }
    }
}

public extension SequentialTrackLease {
    /// Selects and atomically claims a complete record once.
    ///
    /// The system selector sees all baseline records so exhaustion differs from
    /// absence. Its callback runs outside the lease lock. Validation, current
    /// availability, and the claim share one lock acquisition. No failure
    /// contacts a live dependency or returns a previously claimed record.
    /// The claim starts unconsumed. The system calls `markConsumed()` after
    /// replaying all recorded behavior. Progress and consumption acknowledgements
    /// never change availability or choose a continuation.
    func claim<Input: Sendable>(
        matching input: Input,
        using selector: ReplaySelector<Input, Value>)
        throws(SequentialOperationFailure) -> ReplayClaim<Value>
    {
        let snapshot: Result<[SequentialRecord<Value>], SequentialOperationFailure> = state.withLock { state in
            if admissionClosedOrLeaseClosed(state) {
                return .failure(operationFailure(.leaseClosed, context: .track(id)))
            }
            guard mode == .replay else {
                return .failure(operationFailure(.wrongMode(expected: .replay, actual: mode), context: .track(id)))
            }
            return .success(state.baseline)
        }
        let records: [SequentialRecord<Value>]
        switch snapshot {
        case let .success(value): records = value
        case let .failure(failure):
            reporter.record(failure.diagnostic)
            throw failure
        }
        let selection = selector.select(input, records)
        let chosen = state.withLock { state in
            claimSelection(selection, rule: selector.rule, state: &state)
        }
        switch chosen {
        case let .success(record):
            return ReplayClaim(record: record) { identity, action in
                self.updateReplayProgress(identity, action: action)
            }
        case let .failure(failure):
            guard case .sequential(.selection) = failure.diagnostic.issue else {
                reporter.record(failure.diagnostic)
                throw failure
            }
            let diagnostic = Diagnostic(issue: failure.diagnostic.issue, context: failure.diagnostic.context,
                                        fieldPath: selector.differences(input, records), rule: selector.rule)
            reporter.record(diagnostic)
            throw SequentialOperationFailure(diagnostic: diagnostic)
        }
    }
}

private extension SequentialTrackLease {
    private func claimSelection(
        _ selection: ReplaySelection, rule: DiagnosticLabel,
        state: inout State) -> Result<SequentialRecord<Value>, SequentialOperationFailure>
    {
        if admissionClosedOrLeaseClosed(state) {
            return .failure(operationFailure(.leaseClosed, context: .track(id)))
        }
        switch selection {
        case .noMatch:
            return .failure(selectionFailure(.noMatch, context: .track(id), rule: rule))
        case let .ambiguous(identities):
            guard let indices = validSelection(identities, records: state.baseline), indices.count > 1 else {
                return .failure(selectionFailure(.invalidSelectorResult, context: .track(id), rule: rule))
            }
            let ordered = indices.sorted().map { state.baseline[$0].identity }
            return .failure(selectionFailure(.ambiguous(ordered), context: .track(id), rule: rule))
        case let .equivalent(identities):
            guard let indices = validSelection(identities, records: state.baseline) else {
                return .failure(selectionFailure(.invalidSelectorResult, context: .track(id), rule: rule))
            }
            let ordered = indices.sorted()
            guard let index = ordered.first(where: { !state.claimed.contains($0) }) else {
                let matches = ordered.map { state.baseline[$0].identity }
                return .failure(selectionFailure(.exhausted(matches), context: .track(id), rule: rule))
            }
            state.claimed.insert(index)
            state.replayProgress[index] = ReplayClaimProgress()
            return .success(state.baseline[index])
        }
    }

    private func admissionClosedOrLeaseClosed(_ state: State) -> Bool {
        admission.isClosed || state.closed
    }

    func validSelection(_ identities: [RecordIdentity], records: [SequentialRecord<Value>]) -> [Int]? {
        guard !identities.isEmpty else { return nil }
        var seen: Set<Int> = []
        var indices: [Int] = []
        for identity in identities {
            guard identity.trackID == id, identity.sequence < UInt64(records.count),
                  let index = Int(exactly: identity.sequence), records[index].identity == identity,
                  seen.insert(index).inserted else { return nil }
            indices.append(index)
        }
        return indices
    }

    func updateReplayProgress(_ identity: RecordIdentity, action: ReplayProgressAction) -> Bool {
        state.withLock { state in
            // Admission stops new claims first. Already claimed scheduled
            // delivery may still acknowledge progress while finish drains it.
            // The track closes only after that quiescence boundary.
            guard !state.closed, identity.trackID == id,
                  let index = Int(exactly: identity.sequence),
                  var progress = state.replayProgress[index] else { return false }
            switch action {
            case let .advance(count):
                guard !progress.isConsumed else { return false }
                progress.progressCount = max(progress.progressCount, count)
            case .markConsumed:
                progress.isConsumed = true
            }
            state.replayProgress[index] = progress
            return true
        }
    }

    func selectionFailure(
        _ issue: ReplaySelectionIssue, context: DiagnosticContext,
        rule: DiagnosticLabel) -> SequentialOperationFailure
    {
        SequentialOperationFailure(diagnostic: Diagnostic(issue: .sequential(.selection(issue)),
                                                          context: context, rule: rule))
    }
}
