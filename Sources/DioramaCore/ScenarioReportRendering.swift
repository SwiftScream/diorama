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
        var lines = ["Scenario \(ReportText.quote(report.scenarioID.rawValue))"]
        for attachment in usage {
            let mode = ReportText.mode(attachment.mode)
            let verification = attachment.isIgnored ? "ignored" : "included"
            lines.append("Attachment \(ReportText.attachment(attachment.attachmentID)) \(mode) usage=\(verification)")
            for track in attachment.tracks {
                let key = ReportText.quote(track.id.key.rawValue)
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

enum ReportText {
    static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0...0x1F, 0x7F...0x9F, 0x2028...0x202E, 0x2066...0x2069:
                result += "\\u{\(String(scalar.value, radix: 16))}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    static func mode(_ mode: ScenarioMode) -> String {
        switch mode {
        case .record: "record"
        case .replay: "replay"
        case .passthrough: "passthrough"
        }
    }

    static func attachment(_ id: AttachmentID) -> String {
        "system=\(quote(id.systemTypeID.rawValue)) key=\(quote(id.key.rawValue))"
    }

    static func context(_ context: DiagnosticContext) -> String {
        switch context {
        case .scenario: "scenario"
        case let .attachment(id): attachment(id)
        case let .track(id): "\(attachment(id.attachmentID)) track=\(quote(id.key.rawValue))"
        case let .record(id): "\(self.context(.track(id.trackID))) record=\(id.sequence)"
        }
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
        var text = "  [\(entry.sequence)] \(context(fact.context)) \(issue(fact.issue))"
        if !fact.fieldPath.isEmpty {
            text += " fields=[\(fact.fieldPath.map { quote($0.text) }.joined(separator: ", "))]"
        }
        if let rule = fact.rule {
            text += " rule=\(quote(rule.text))"
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
        case let .system(label): "system-issue \(quote(label.text))"
        case .verification(.recordingNotAdmitted): "recording-not-admitted"
        case let .sequential(.wrongMode(expected, actual)):
            "wrong-mode expected=\(mode(expected)) actual=\(mode(actual))"
        case let .sequential(.replayExhausted(availableCount)):
            "replay-exhausted available=\(availableCount)"
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
