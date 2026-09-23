public extension ScenarioFinalizationResult {
    /// Renders ordered, safe facts without inspecting recorded values or errors.
    ///
    /// Diorama owns the text format; it is a human-readable report, not a
    /// persistence schema. Setup-authored identities and labels are quoted
    /// with controls escaped. There are no timestamps, native descriptions,
    /// process identities, locale-dependent numbers, or test-outcome flags.
    ///
    /// - Returns: A deterministic multiline description of this frozen result.
    func rendered() -> String {
        var lines = ["Scenario \(ReportFieldEscaping.quote(report.scenarioID.rawValue))"]
        for attachment in usage {
            let mode = ReportText.mode(attachment.mode)
            let verification = attachment.allowsUnusedReplayRecords ? "ignored" : "included"
            lines.append("Attachment \(ReportText.attachment(attachment.attachmentID)) \(mode) usage=\(verification)")
            for track in attachment.tracks {
                let key = ReportFieldEscaping.quote(track.id.key.rawValue)
                lines.append("  Track \(key) \(ReportText.activity(track.activity))")
                for record in track.unusedRecords {
                    lines.append("    Unused record \(record.sequence)")
                }
            }
        }
        lines.append("Diagnostics \(report.diagnostics.count)")
        for entry in report.diagnostics {
            lines.append(ReportText.diagnostic(entry))
        }
        lines.append("Recording health \(report.recordingHealth.isHealthy ? "healthy" : "unhealthy")")
        for outcome in cleanup {
            let disposition = outcome.disposition == .completed ? "completed" : "failed"
            lines.append("Cleanup \(ReportText.attachment(outcome.attachmentID)) \(disposition)")
        }
        return lines.joined(separator: "\n")
    }
}

package extension DiagnosticContext {
    /// Stable, escaped identity fields for a human-readable report.
    func renderedForReport() -> String {
        switch self {
        case .scenario: "scenario"
        case let .attachment(id): ReportText.attachment(id)
        case let .track(id):
            "\(ReportText.attachment(id.attachmentID)) track=\(ReportFieldEscaping.quote(id.key.rawValue))"
        case let .record(id): "\(DiagnosticContext.track(id.trackID).renderedForReport()) record=\(id.sequence)"
        }
    }
}

enum ReportText {
    static func mode(_ mode: ScenarioMode) -> String {
        switch mode {
        case .record: "record"
        case .replay: "replay"
        case .passthrough: "passthrough"
        }
    }

    static func attachment(_ id: AttachmentID) -> String {
        "system=\(ReportFieldEscaping.quote(id.systemTypeID.rawValue)) "
            + "key=\(ReportFieldEscaping.quote(id.key.rawValue))"
    }

    static func activity(_ activity: SequentialTrackUsage.Activity) -> String {
        switch activity {
        case let .record(recorded, incomplete): "record admitted=\(recorded) incomplete=\(incomplete)"
        case let .replay(used, unused): "replay used=\(used) unused=\(unused)"
        case .passthrough: "passthrough"
        }
    }

    static func diagnostic(_ entry: ReportedDiagnostic) -> String {
        let fact = entry.diagnostic
        var text = "  [\(entry.sequence)] \(fact.context.renderedForReport()) \(issue(fact.issue))"
        if !fact.fieldPath.isEmpty {
            text += " fields=[\(fact.fieldPath.map { ReportFieldEscaping.quote($0.text) }.joined(separator: ", "))]"
        }
        if let rule = fact.rule {
            text += " rule=\(ReportFieldEscaping.quote(rule.text))"
        }
        if fact.recordingImpact == .invalidatesCandidate {
            text += " invalidates-recording"
        }
        return text
    }

    static func issue(_ issue: DiagnosticIssue) -> String {
        switch issue {
        case .conversionFailed: "conversion-failed"
        case let .preparationFailed(stage): "preparation-failed \(preparation(stage))"
        case .sinkFailed: "sink-failed"
        case let .lifecycle(fact): lifecycle(fact)
        case let .baseline(fact): baseline(fact)
        case let .system(label): "system-issue \(ReportFieldEscaping.quote(label.text))"
        case let .logicalTime(fact): logicalTime(fact)
        case .verification(.recordingNotAdmitted): "recording-not-admitted"
        case let .sequential(.wrongMode(expected, actual)):
            "wrong-mode expected=\(mode(expected)) actual=\(mode(actual))"
        case let .sequential(.replayExhausted(availableCount)):
            "replay-exhausted available=\(availableCount)"
        }
    }

    private static func logicalTime(_ issue: ExecutionTimeIssue) -> String {
        switch issue {
        case .notStarted: "logical-time-not-started"
        case .executionClosed: "logical-time-execution-closed"
        case .clockMovedBackward: "logical-time-clock-moved-backward"
        case .foreignCapture: "logical-time-foreign-capture"
        case .reversedCaptures: "logical-time-reversed-captures"
        case .negativeDelay: "logical-time-negative-delay"
        case .overflow: "logical-time-overflow"
        }
    }

    private static func baseline(_ issue: ScenarioBaselineIssue) -> String {
        switch issue {
        case .invalidPersistenceConfiguration:
            "invalid-persistence-configuration"
        case let .requiredBaselineUnavailable(problem):
            "required-baseline-unavailable reason=\(baselineProblem(problem))"
        case .replayAttachmentMissing:
            "replay-attachment-missing"
        case .loadedAttachmentNotConfigured:
            "loaded-attachment-not-configured preservation=discarded"
        case let .baselineIgnoredForRecording(problem):
            "baseline-ignored-for-recording reason=\(baselineProblem(problem)) preservation=lost"
        }
    }

    private static func baselineProblem(_ problem: ScenarioBaselineProblem) -> String {
        switch problem {
        case .missing: "missing"
        case .unreadable: "unreadable"
        case .invalidDocument: "invalid-document"
        case .incompatibleEnvelope: "incompatible-envelope"
        case .incompatibleSystem: "incompatible-system"
        case .incompatibleSetup: "incompatible-setup"
        }
    }

    private static func preparation(_ stage: PreparationStage) -> String {
        switch stage {
        case .normalization: "normalization"
        case .redaction: "redaction"
        case .validation: "validation"
        case .canonicalization: "canonicalization"
        }
    }

    private static func lifecycle(_ issue: ScenarioLifecycleIssue) -> String {
        switch issue {
        case .invalidRegistration: "invalid-registration"
        case .preparationFailed: "system-preparation-failed"
        case .unpreparedTrack: "unprepared-track"
        case .invalidTrackRequest: "invalid-track-request"
        case .preparationClosed: "preparation-closed"
        case .activationFailed: "activation-failed"
        case .cleanupFailed: "cleanup-failed"
        case .leaseClosed: "lease-closed"
        case .executionClosed: "execution-closed"
        case .invalidDependencyRequest: "invalid-dependency-request"
        }
    }
}
