import DioramaCore
import DioramaPersistence

/// Evidence about the document observed at startup, before this run published.
public enum PriorDocument: Equatable, Sendable {
    case notApplicable
    case present
    case absent
    case unknown
}

/// The effect of this run's publication attempt on its configured destination.
/// Concurrent writers may still change the destination independently.
public enum PublicationPreservation: Equatable, Sendable {
    case notApplicable
    case unchangedByThisRun
    case committedByThisRun
}

/// Safe stage of an issue that prevented or followed publication.
public enum PublicationStage: Equatable, Sendable {
    case conversion
    case preparation(PreparationStage)
    case recording
    case encoding
    case storage(FileStorageOperation?)
    case cleanup
}

/// Bounded cause information; no arbitrary error description or payload is stored.
public enum PublicationCause: Equatable, Sendable {
    case diagnostic(UInt64)
    case file(FileStorageFailureCode)
    case persistence(PersistenceDispatchError)
    case unspecified
}

/// One safe, stage-specific reason for refusal or a publication problem.
public struct PublicationIssue: Equatable, Sendable {
    public let stage: PublicationStage
    public let context: DiagnosticContext
    public let cause: PublicationCause

    init(stage: PublicationStage, context: DiagnosticContext = .scenario, cause: PublicationCause) {
        self.stage = stage
        self.context = context
        self.cause = cause
    }
}

/// Payload-free counts for the completed candidate or attempted recording.
/// `recordedCount` counts observations from this run, not preserved baseline data.
public struct PublicationCandidateSummary: Equatable, Sendable {
    public let isComplete: Bool
    public let attachmentCount: Int
    public let trackCount: Int
    public let recordedCount: UInt64
    public let incompleteCount: UInt64
}

/// Safe, immutable aggregate of finalization and optional publication evidence.
/// The semantic definition and underlying errors remain separately inspectable
/// through ``DioramaResult`` and ``DioramaPublication``.
public struct DioramaReport: Equatable, Sendable {
    public enum Disposition: Equatable, Sendable {
        case notRequested
        case refusedUnhealthy
        case published
        case failed
    }

    public let scenarioID: ScenarioID
    public let priorDocument: PriorDocument
    public let disposition: Disposition
    public let preservation: PublicationPreservation
    public let candidate: PublicationCandidateSummary
    public let diagnostics: [ReportedDiagnostic]
    public let issues: [PublicationIssue]

    private let finalizationText: String

    init(finalization: ScenarioFinalizationResult, publication: DioramaPublication,
         loadResult: ScenarioLoadResult?)
    {
        scenarioID = finalization.report.scenarioID
        priorDocument = Self.priorDocument(loadResult)
        diagnostics = finalization.report.diagnostics
        let recording = finalization.usage.flatMap(\.tracks).compactMap { track -> (UInt64, UInt64)? in
            if case let .record(recorded, incomplete) = track.activity {
                return (recorded, incomplete)
            }
            return nil
        }
        candidate = PublicationCandidateSummary(
            isComplete: finalization.definition != nil,
            attachmentCount: finalization.usage.count,
            trackCount: finalization.usage.reduce(0) { $0 + $1.tracks.count },
            recordedCount: recording.reduce(0) { $0 + $1.0 },
            incompleteCount: recording.reduce(0) { $0 + $1.1 })
        finalizationText = finalization.rendered()

        var problems = finalization.report.recordingHealth.failures.map { entry in
            PublicationIssue(stage: Self.stage(entry.diagnostic.issue), context: entry.diagnostic.context,
                             cause: .diagnostic(entry.sequence))
        }
        switch publication {
        case .notRequested:
            disposition = .notRequested
            preservation = .notApplicable
        case .refusedUnhealthy:
            disposition = .refusedUnhealthy
            preservation = .unchangedByThisRun
        case let .published(receipt):
            disposition = .published
            preservation = .committedByThisRun
            if let error = receipt.cleanupFailure {
                problems.append(Self.issue(for: error, committed: true))
            }
        case let .failed(error):
            disposition = .failed
            preservation = .unchangedByThisRun
            switch error {
            case let .encoding(cause):
                problems.append(PublicationIssue(stage: .encoding, cause: Self.cause(cause)))
            case let .storage(cause):
                problems.append(Self.issue(for: cause, committed: false))
                if let file = cause as? FileStorageError, let cleanup = file.cleanupFailure {
                    problems.append(PublicationIssue(stage: .cleanup, cause: .file(cleanup)))
                }
            }
        }
        issues = problems
    }

    /// Deterministic text using only safe diagnostics, identities, counts, and codes.
    public func rendered() -> String {
        var lines = [finalizationText]
        lines.append("Publication scenario=\(ReportFieldEscaping.quote(scenarioID.rawValue)) "
            + "prior=\(Self.priorName(priorDocument)) "
            + "disposition=\(Self.dispositionName(disposition)) "
            + "preservation=\(Self.preservationName(preservation))")
        lines.append("Candidate \(candidate.isComplete ? "complete" : "unavailable") "
            + "attachments=\(candidate.attachmentCount) tracks=\(candidate.trackCount) "
            + "recorded=\(candidate.recordedCount) incomplete=\(candidate.incompleteCount)")
        for issue in issues {
            lines.append("Publication issue stage=\(Self.stageName(issue.stage)) "
                + "\(issue.context.renderedForReport()) cause=\(Self.causeName(issue.cause))")
        }
        return lines.joined(separator: "\n")
    }

    private static func priorDocument(_ load: ScenarioLoadResult?) -> PriorDocument {
        guard let load else { return .notApplicable }
        return switch load {
        case .loaded, .invalidDocument, .incompatibleEnvelope, .incompatibleSystem: .present
        case .missing: .absent
        case .unreadable: .unknown
        }
    }

    private static func stage(_ issue: DiagnosticIssue) -> PublicationStage {
        switch issue {
        case .conversionFailed: .conversion
        case let .preparationFailed(stage): .preparation(stage)
        case .lifecycle(.cleanupFailed): .cleanup
        case .sinkFailed, .lifecycle, .baseline, .sequential, .logicalTime, .verification, .system: .recording
        }
    }

    private static func issue(for error: any Error, committed: Bool) -> PublicationIssue {
        if let file = error as? FileStorageError {
            return PublicationIssue(stage: committed ? .cleanup : .storage(file.operation),
                                    cause: .file(file.cause))
        }
        return PublicationIssue(stage: committed ? .cleanup : .storage(nil), cause: cause(error))
    }

    private static func cause(_ error: any Error) -> PublicationCause {
        if let dispatch = error as? PersistenceDispatchError {
            return .persistence(dispatch)
        }
        if let file = error as? FileStorageError {
            return .file(file.cause)
        }
        return .unspecified
    }

    private static func priorName(_ value: PriorDocument) -> String {
        switch value {
        case .notApplicable: "not-applicable"
        case .present: "present"
        case .absent: "absent"
        case .unknown: "unknown"
        }
    }

    private static func dispositionName(_ value: Disposition) -> String {
        switch value {
        case .notRequested: "not-requested"
        case .refusedUnhealthy: "refused-unhealthy"
        case .published: "published"
        case .failed: "failed"
        }
    }

    private static func preservationName(_ value: PublicationPreservation) -> String {
        switch value {
        case .notApplicable: "not-applicable"
        case .unchangedByThisRun: "unchanged-by-this-run"
        case .committedByThisRun: "committed-by-this-run"
        }
    }

    private static func stageName(_ value: PublicationStage) -> String {
        switch value {
        case .conversion: "conversion"
        case let .preparation(stage): "preparation-\(preparationName(stage))"
        case .recording: "recording"
        case .encoding: "encoding"
        case let .storage(operation): "storage-\(operation.map(storageName) ?? "unknown")"
        case .cleanup: "cleanup"
        }
    }

    private static func preparationName(_ value: PreparationStage) -> String {
        switch value {
        case .canonicalization: "canonicalization"
        case .redaction: "redaction"
        case .normalization: "normalization"
        case .validation: "validation"
        }
    }

    private static func storageName(_ value: FileStorageOperation) -> String {
        switch value {
        case .read: "read"
        case .stage: "stage"
        case .commit: "commit"
        case .cleanup: "cleanup"
        }
    }

    private static func causeName(_ value: PublicationCause) -> String {
        switch value {
        case let .diagnostic(sequence): "diagnostic-\(sequence)"
        case let .file(.posix(code)): "posix-\(code)"
        case let .file(.cocoa(code)): "cocoa-\(code)"
        case .file(.other): "file-other"
        case let .persistence(.unknownSystemType(id)):
            "unknown-system-type-\(ReportFieldEscaping.quote(id.rawValue))"
        case let .persistence(.unsupportedSchemaVersion(id, declared, supported)):
            "unsupported-schema-\(ReportFieldEscaping.quote(id.rawValue))-\(declared)-\(supported)"
        case let .persistence(.incompatibleRegistration(expected, decoded)):
            "incompatible-registration-\(DiagnosticContext.attachment(expected).renderedForReport())-"
                + "\(DiagnosticContext.attachment(decoded).renderedForReport())"
        case .unspecified: "unspecified"
        }
    }
}
