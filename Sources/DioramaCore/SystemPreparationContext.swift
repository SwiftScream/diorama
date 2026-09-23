import Synchronization

/// The short-lived preparation boundary for one execution's system instance.
///
/// Every declared track must receive a typed lease and policy before activation.
/// Existing stable values receive validation-only persisted admission under
/// that setup policy. A passthrough lease validates identity but never reads
/// content. An escaped context is closed and releases all definition content
/// and leases.
public final class SystemPreparationContext: Sendable {
    private struct State: Sendable {
        var attachment: ScenarioAttachment?
        var requested: Set<TrackID> = []
        var leases: [any AnySequentialLease] = []
    }

    /// The attachment being prepared.
    public let attachmentID: AttachmentID
    /// The resolved whole-attachment mode.
    public let mode: ScenarioMode
    /// The independent reporter for this startup attempt and execution.
    public let reporter: DiagnosticReporter
    /// The execution's shared logical-time and observation-capture service.
    /// Its origin becomes available after all systems activate.
    public let time: ExecutionTime

    private let state: Mutex<State>
    private let admission: ExecutionAdmission

    init(attachment: ScenarioAttachment, mode: ScenarioMode,
         reporter: DiagnosticReporter, admission: ExecutionAdmission, time: ExecutionTime)
    {
        attachmentID = attachment.id
        self.mode = mode
        self.reporter = reporter
        self.time = time
        self.admission = admission
        state = Mutex(State(attachment: attachment))
    }

    /// Prepares one declared track and creates its fresh sequential lease.
    ///
    /// Call exactly once for each declared track. Existing values are validated
    /// outside the context lock without rerunning capture transformations;
    /// failed or abandoned requests cannot authorize activation. The selected
    /// policy is not retained by the lease. Systems use their own immutable
    /// policy for later observations.
    ///
    /// - Parameters:
    ///   - id: The declared track identity for this attachment.
    ///   - preparation: The system's setup-selected policy for its stable type.
    /// - Returns: A fresh typed lease, closed on rollback or finalization.
    /// - Throws: Safe, already-reported admission or track-request evidence.
    public func lease<Value: Sendable>(
        for id: TrackID,
        preparation: ValuePreparation<Value>) throws(PreparationFailure) -> SequentialTrackLease<Value>
    {
        let original: SequentialTrack<Value>
        do {
            original = try state.withLock { state in
                guard let attachment = state.attachment else {
                    throw ScenarioLifecycleIssue.preparationClosed
                }
                guard !state.requested.contains(id),
                      let track = try attachment.track(id, as: Value.self)
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

        let values: [PreparedValue<Value>] = if mode == .passthrough {
            []
        } else {
            try original.records.map { record throws(PreparationFailure) in
                try preparation.admitPrepared(
                    record.value,
                    reporter: reporter,
                    context: .record(record.identity))
            }
        }
        let lease = SequentialTrackLease(
            track: SequentialTrack(id: id, values: values), mode: mode, reporter: reporter, admission: admission)
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
        let missing = detached.attachment?.trackIDs.filter { !prepared.contains($0) } ?? []
        return (detached.leases, missing)
    }

    private func failure(_ issue: ScenarioLifecycleIssue, context: DiagnosticContext) -> PreparationFailure {
        let diagnostic = Diagnostic(issue: .lifecycle(issue), context: context)
        reporter.record(diagnostic)
        return PreparationFailure(diagnostic: diagnostic)
    }
}

extension ScenarioLifecycleIssue: Error {}
