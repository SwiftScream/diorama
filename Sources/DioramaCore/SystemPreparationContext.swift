import Synchronization

/// The short-lived preparation boundary for one execution's system instance.
///
/// Every record/replay track receives a typed lease and policy before activation.
/// Existing stable values receive validation-only persisted admission under
/// that setup policy. Passthrough creates no leases and runs no content policies.
/// An escaped context is closed and releases all definition content
/// and leases.
final class SystemPreparationContext: Sendable {
    private struct State: Sendable {
        var attachment: ScenarioAttachment?
        var requested: Set<TrackID> = []
        var leases: [any AnySequentialLease] = []
    }

    /// The attachment being prepared.
    let attachmentID: AttachmentID
    /// The resolved whole-attachment mode.
    let mode: ScenarioMode
    /// The independent reporter for this startup attempt and execution.
    let reporter: DiagnosticReporter
    /// The execution's shared logical-time and observation-capture service.
    /// Its origin becomes available after all systems activate.
    let time: ExecutionTime
    /// The same execution clock exposed to application consumers after startup.
    let clock: ScenarioClock
    /// This attachment's ordered handoff registration service.
    /// Scheduling becomes available when execution startup completes.
    let scheduling: SchedulingLease

    private let state: Mutex<State>
    let admission: ExecutionAdmission

    init(attachment: ScenarioAttachment, mode: ScenarioMode,
         reporter: DiagnosticReporter, admission: ExecutionAdmission, time: ExecutionTime, clock: ScenarioClock,
         scheduling: SchedulingLease)
    {
        attachmentID = attachment.id
        self.mode = mode
        self.reporter = reporter
        self.time = time
        self.clock = clock
        self.scheduling = scheduling
        self.admission = admission
        state = Mutex(State(attachment: attachment))
    }

    /// Prepares one declared track and creates its fresh sequential lease.
    ///
    /// Call exactly once for each declared record/replay track. Passthrough
    /// rejects lease requests. Existing values are validated
    /// outside the context lock without rerunning capture transformations;
    /// failed or abandoned requests cannot authorize activation. The selected
    /// preparation policy is retained only when a recording merge needs final
    /// validation. Systems use their own immutable policy for later observations.
    /// Synchronous replay returns the stored value;
    /// systems translate it into their domain objects.
    ///
    /// - Parameters:
    ///   - id: The declared track identity for this attachment.
    ///   - preparation: The system's setup-selected policy for its stable type.
    ///   - continuationPolicy: Exhausted and closed replay behavior; defaults to throwing.
    ///   - mergeRecording: Optional typed baseline/fresh merge at finalization.
    ///     The result receives validation only, with capture transforms omitted.
    /// - Returns: A fresh typed lease, closed on rollback or finalization.
    /// - Throws: Safe, already-reported admission or track-request evidence.
    func lease<Value: Sendable>(
        for id: TrackID,
        preparation: ValuePreparation<Value>,
        continuationPolicy: ReplayContinuationPolicy<Value> = .error,
        mergeRecording: RecordingMerge<Value, Void>? = nil)
        throws(PreparationFailure) -> HeaderlessSequentialTrackLease<Value>
    {
        let policy = mergeRecording.map {
            FinalRecordingMerge(merge: $0, valuePreparation: preparation, headerPreparation: ValuePreparation<Void>())
        }
        return try lease(for: id, preparation: preparation, admitHeader: { (_: Void) in () },
                         continuationPolicy: continuationPolicy, recordingMerge: policy)
    }

    /// Prepares a track with one typed header outside its record sequence.
    /// Existing header content receives validation-only admission, including
    /// when its record sequence is empty.
    /// An optional recording merge receives typed baseline and fresh tracks,
    /// including their headers. Its output is validated with these policies.
    func lease<Value: Sendable, Header: Sendable>(
        for id: TrackID,
        preparation: ValuePreparation<Value>,
        headerPreparation: ValuePreparation<Header>,
        continuationPolicy: ReplayContinuationPolicy<Value> = .error,
        mergeRecording: RecordingMerge<Value, Header>? = nil)
        throws(PreparationFailure) -> SequentialTrackLease<Value, Header>
    {
        func admit(_ header: Header) throws(PreparationFailure) -> Header {
            try headerPreparation.admitPrepared(
                header, reporter: reporter, context: .track(id)).value
        }
        let policy = mergeRecording.map {
            FinalRecordingMerge(merge: $0, valuePreparation: preparation, headerPreparation: headerPreparation)
        }
        return try lease(for: id, preparation: preparation, admitHeader: admit,
                         continuationPolicy: continuationPolicy, recordingMerge: policy)
    }

    private func lease<Value: Sendable, Header: Sendable>(
        for id: TrackID,
        preparation: ValuePreparation<Value>,
        admitHeader: (Header) throws(PreparationFailure) -> Header,
        continuationPolicy: ReplayContinuationPolicy<Value>,
        recordingMerge: FinalRecordingMerge<Value, Header>?)
        throws(PreparationFailure) -> SequentialTrackLease<Value, Header>
    {
        guard mode != .passthrough else { throw failure(.invalidTrackRequest, context: .track(id)) }
        let original: SequentialTrack<Value, Header>
        do {
            original = try state.withLock { state in
                guard let attachment = state.attachment else {
                    throw ScenarioLifecycleIssue.preparationClosed
                }
                guard !state.requested.contains(id),
                      let track = try attachment.track(id, as: Value.self, header: Header.self)
                else {
                    throw ScenarioLifecycleIssue.invalidTrackRequest
                }
                state.requested.insert(id)
                return track
            }
        } catch {
            let issue = (error as? ScenarioLifecycleIssue) ?? .invalidTrackRequest
            throw failure(issue, context: .track(id))
        }

        let admittedHeader = try admitHeader(original.header)
        let records = try original.records.map { record throws(PreparationFailure) in
            let prepared = try preparation.admitPrepared(
                record.value, reporter: reporter, context: .record(record.identity))
            return SequentialRecord(identity: record.identity, value: prepared.value)
        }
        let lease = SequentialTrackLease(
            track: original, baseline: records, baselineHeader: admittedHeader,
            mode: mode, reporter: reporter, admission: admission,
            continuationPolicy: continuationPolicy, recordingMerge: recordingMerge)
        let admitted = state.withLock { state in
            guard state.attachment != nil else { return false }
            state.leases.append(lease)
            return true
        }
        guard admitted else {
            lease.close()
            throw failure(.preparationClosed, context: .track(id))
        }
        return lease
    }

    func end() -> (leases: [any AnySequentialLease], missing: [TrackID]) {
        let detached = state.withLock { state in
            let detached = state
            state = State()
            return detached
        }
        let prepared = Set(detached.leases.map(\.id))
        let missing = mode == .passthrough ? [] : detached.attachment?.trackIDs.filter { !prepared.contains($0) } ?? []
        return (detached.leases, missing)
    }

    private func failure(_ issue: ScenarioLifecycleIssue, context: DiagnosticContext) -> PreparationFailure {
        let diagnostic = Diagnostic(issue: .lifecycle(issue), context: context)
        reporter.record(diagnostic)
        return PreparationFailure(diagnostic: diagnostic)
    }
}

extension ScenarioLifecycleIssue: Error {}
