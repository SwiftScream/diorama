/// A consumer-selected condition, never an implicit test outcome.
public enum ScenarioEvaluationCondition: Equatable, Sendable {
    /// No core operation failed because of exhaustion, mode, or invalid access.
    /// System labels have no universal meaning; use `noDiagnostics` to include them.
    case noUnexpectedOperations
    /// No diagnostics of any category occurred before the result froze.
    case noDiagnostics
    /// All nonignored replay records were used.
    case allRecordingsUsed
    /// No selected diagnostic invalidates the recording candidate.
    case healthyRecording
    /// Every selected attachment's cleanup completed successfully.
    case successfulCleanup
}

/// One safe fact that does not satisfy an explicitly selected condition.
public enum ScenarioEvaluationFailure: Equatable, Sendable {
    /// A requested attachment key does not occur in the result.
    case unknownAttachment(AttachmentKey)
    /// A retained diagnostic violates the selected condition.
    case diagnostic(ReportedDiagnostic)
    /// A replay record was never claimed.
    case unusedRecord(RecordIdentity)
    /// An activated attachment's cleanup failed.
    case cleanup(AttachmentCleanup)
}

/// The result of a deliberate, framework-independent evaluation.
public struct ScenarioEvaluation: Equatable, Sendable {
    /// The condition explicitly requested by the consumer.
    public let condition: ScenarioEvaluationCondition
    /// Unknown keys first in lexical order, then facts in final report order.
    public let failures: [ScenarioEvaluationFailure]
    /// Whether the selected condition holds for the requested scope.
    public var isSatisfied: Bool {
        failures.isEmpty
    }
}

public extension ScenarioFinalizationResult {
    /// Evaluates frozen facts without reporting test failures or new diagnostics.
    ///
    /// A selected attachment scope excludes scenario-level diagnostics. Ignored
    /// keys affect only `allRecordingsUsed`; all other conditions inspect them.
    /// An unknown selected key yields a failure instead of vacuous success.
    /// Late diagnostics stay in the separately retained reporter and cannot
    /// change this evaluation. Sequential claims complete synchronously, so
    /// this capability has no separate incomplete replay lifecycle to evaluate.
    ///
    /// - Parameters:
    ///   - condition: The policy the caller deliberately chooses to evaluate.
    ///   - attachments: Keys to inspect, or `nil` for the whole scenario.
    ///     An empty set deliberately selects no attachments.
    /// - Returns: Ordered safe evidence and satisfaction of this condition.
    func evaluate(_ condition: ScenarioEvaluationCondition,
                  attachments: Set<AttachmentKey>? = nil) -> ScenarioEvaluation
    {
        let known = Set(usage.map(\.attachmentID.key))
        let unknown = (attachments ?? []).subtracting(known).sorted { $0.rawValue < $1.rawValue }
        let selected = usage.filter { attachments?.contains($0.attachmentID.key) ?? true }
        let diagnostics = report.diagnostics.filter { entry in
            guard let attachments else { return true }
            guard let key = entry.diagnostic.context.attachmentID?.key else { return false }
            return attachments.contains(key)
        }
        let facts: [ScenarioEvaluationFailure] = switch condition {
        case .noUnexpectedOperations:
            diagnostics.filter(\.diagnostic.issue.isUnexpectedOperation).map {
                .diagnostic($0)
            }
        case .noDiagnostics:
            diagnostics.map { .diagnostic($0) }
        case .allRecordingsUsed:
            selected.filter { !$0.isIgnored }.flatMap { attachment in
                attachment.tracks.flatMap { track in
                    track.unusedRecords.map { .unusedRecord($0) }
                }
            }
        case .healthyRecording:
            diagnostics.filter { $0.diagnostic.recordingImpact == .invalidatesCandidate }.map {
                .diagnostic($0)
            }
        case .successfulCleanup:
            cleanup.filter {
                (attachments?.contains($0.attachmentID.key) ?? true) && $0.disposition == .failed
            }.map { .cleanup($0) }
        }
        return ScenarioEvaluation(condition: condition, failures: unknown.map { .unknownAttachment($0) } + facts)
    }
}

private extension DiagnosticIssue {
    var isUnexpectedOperation: Bool {
        switch self {
        case .sequential: true
        case let .lifecycle(issue):
            switch issue {
            case .invalidTrackRequest, .preparationClosed, .leaseClosed, .executionClosed, .invalidDependencyRequest:
                true
            case .invalidRegistration, .preparationFailed, .unpreparedTrack, .activationFailed, .cleanupFailed: false
            }
        case .conversionFailed, .preparationFailed, .sinkFailed, .verification, .system: false
        }
    }
}
