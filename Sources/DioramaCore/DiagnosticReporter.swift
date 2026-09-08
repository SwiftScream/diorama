import Synchronization

/// A reusable, closure-backed destination for safe diagnostic notifications.
///
/// Calls are synchronous, may overlap, and may reenter the reporter. The sink
/// must synchronize its own state. A thrown error yields a retained
/// `sinkFailed` fact; its description is never inspected or retained.
public struct DiagnosticSink: Sendable {
    let receive: @Sendable (ReportedDiagnostic) throws -> Void

    /// Creates a sink without coupling Diorama to a test framework.
    ///
    /// - Parameter receive: A callback invoked after retention, outside the
    ///   reporter's lock. Do not strongly capture an owner of this sink, such
    ///   as its reporter or execution, unless you explicitly break that cycle.
    public init(_ receive: @escaping @Sendable (ReportedDiagnostic) throws -> Void) {
        self.receive = receive
    }
}

/// A separately retainable, synchronous diagnostic ledger and post-finish log.
///
/// Retention precedes sink delivery. Inspection returns immutable snapshots;
/// callback completion order does not determine report ordering. Only identity
/// metadata and safe diagnostics are retained, never definition track values.
/// Consumer sink captures remain the consumer's ownership responsibility.
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
    private let sink: DiagnosticSink?
    private let state = Mutex(State())

    /// Creates an independent reporter using a definition's identity order.
    ///
    /// - Parameters:
    ///   - definition: The source of scenario, attachment, and track identities.
    ///     Content, policies, and the definition itself are not retained.
    ///   - sink: Optional immediate notification after each retained fact.
    public init(definition: ScenarioDefinition, sink: DiagnosticSink? = nil) {
        scenarioID = definition.id
        ordering = DiagnosticOrdering(attachments: definition.attachments)
        self.sink = sink
    }

    /// The active ledger, or its immutable snapshot once internally frozen.
    ///
    /// Scenario-level facts come first, followed by declaration order and
    /// record sequence. Undeclared identities follow declared ones in lexical
    /// system/key order. Admission sequence breaks ties within one context.
    public var report: DiagnosticReport {
        state.withLock { state in
            switch state.phase {
            case .collecting: makeReport(state.active)
            case let .frozen(report): report
            }
        }
    }

    /// Facts reported after the immutable report boundary, even without a sink.
    ///
    /// Uses the same deterministic context ordering as ``report``. These facts
    /// never modify the frozen report or its recording-health snapshot.
    public var postFinishDiagnostics: [ReportedDiagnostic] {
        let entries = state.withLock { $0.postFinish }
        return entries.sorted(by: ordering.precedes)
    }

    /// Retains a safe fact, updates health, then invokes the optional sink.
    ///
    /// A reentrant or throwing sink cannot remove the original entry. Sink
    /// failures are retained without notifying the same sink recursively.
    /// No sink callback runs under the state lock. Concurrent callbacks can
    /// overlap and finish in a different order from retained facts.
    ///
    /// - Parameter diagnostic: Already safe infrastructure or verification data.
    public func record(_ diagnostic: Diagnostic) {
        let entry = retain(diagnostic)
        do {
            try sink?.receive(entry)
        } catch {
            _ = retain(Diagnostic(issue: .sinkFailed, context: diagnostic.context))
        }
    }

    /// The execution owner will call this at its final-result freeze boundary.
    /// It freezes only diagnostic facts, not an execution or adapter lifecycle.
    func freeze() -> DiagnosticReport {
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

    private func retain(_ diagnostic: Diagnostic) -> ReportedDiagnostic {
        state.withLock { state in
            let entry = ReportedDiagnostic(sequence: state.nextSequence, diagnostic: diagnostic)
            state.nextSequence += 1
            switch state.phase {
            case .collecting:
                state.active.append(entry)
            case .frozen:
                state.postFinish.append(entry)
            }
            return entry
        }
    }

    private func makeReport(_ entries: [ReportedDiagnostic]) -> DiagnosticReport {
        DiagnosticReport(scenarioID: scenarioID, diagnostics: entries.sorted(by: ordering.precedes))
    }
}
