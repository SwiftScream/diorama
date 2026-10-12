import Synchronization

/// A separately retainable, synchronous diagnostic ledger and post-finish log.
///
/// Recording retains safe facts without invoking consumer code. Only a frozen
/// report is publicly inspectable; no running snapshot is exposed. The reporter
/// retains identity metadata and diagnostics, never definition track values.
public final class DiagnosticReporter: Sendable {
    private enum Phase: Sendable {
        case collecting
        case frozen(DiagnosticReport)
    }

    private struct State: Sendable {
        var phase: Phase = .collecting
        var active: [ReportedDiagnostic] = []
        var postFinish: [ReportedDiagnostic] = []
        var nextSequence: UInt64 = 0
    }

    /// The scenario identity shared by this reporter's snapshots.
    public let scenarioID: ScenarioID

    private let ordering: DiagnosticOrdering
    private let state = Mutex(State())

    /// Creates an independent reporter using explicit identity and attachment order.
    ///
    /// - Parameters:
    ///   - scenarioID: Diagnostic identity supplied by runtime configuration.
    ///   - definition: Attachment and track identities; content is not retained.
    public init(scenarioID: ScenarioID, definition: ScenarioDefinition) {
        self.scenarioID = scenarioID
        ordering = DiagnosticOrdering(attachments: definition.attachments)
    }

    /// The immutable completed report, or nil until the execution owner freezes it.
    ///
    /// Scenario-level facts come first, followed by declaration order and
    /// record sequence. Undeclared identities follow declared ones in lexical
    /// system/key order. Admission sequence breaks ties within one context.
    public var report: DiagnosticReport? {
        state.withLock { state in
            switch state.phase {
            case .collecting: nil
            case let .frozen(report): report
            }
        }
    }

    /// Facts reported after the immutable report boundary.
    ///
    /// Uses the same deterministic context ordering as ``report``. These facts
    /// never modify the frozen report or its recording-health snapshot.
    public var postFinishDiagnostics: [ReportedDiagnostic] {
        let entries = state.withLock { $0.postFinish }
        return entries.sorted(by: ordering.precedes)
    }

    /// Retains a safe fact and its recording impact atomically, without callbacks.
    ///
    /// A fact racing freeze enters exactly one of the final or post-finish logs.
    /// Reporting never throws or calls consumer code.
    ///
    /// - Parameter diagnostic: Already safe infrastructure or verification data.
    public func record(_ diagnostic: Diagnostic) {
        state.withLock { state in
            let entry = ReportedDiagnostic(sequence: state.nextSequence, diagnostic: diagnostic)
            state.nextSequence += 1
            switch state.phase {
            case .collecting:
                state.active.append(entry)
            case .frozen:
                state.postFinish.append(entry)
            }
        }
    }

    /// Internal candidate admission must see invalidating facts before freeze.
    /// Late facts cannot change the completed candidate's health.
    var isRecordingHealthy: Bool {
        state.withLock { state in
            switch state.phase {
            case .collecting: !state.active.contains { $0.diagnostic.recordingImpact == .invalidatesCandidate }
            case let .frozen(report): report.recordingHealth.isHealthy
            }
        }
    }

    /// The execution owner will call this at its final-result freeze boundary.
    /// It freezes only diagnostic facts, not an execution or adapter lifecycle.
    package func freeze() -> DiagnosticReport {
        state.withLock { state in
            switch state.phase {
            case .collecting:
                let report = makeReport(state.active)
                state.phase = .frozen(report)
                state.active = []
                return report
            case let .frozen(report):
                return report
            }
        }
    }

    private func makeReport(_ entries: [ReportedDiagnostic]) -> DiagnosticReport {
        DiagnosticReport(scenarioID: scenarioID, diagnostics: entries.sorted(by: ordering.precedes))
    }
}
