import DioramaCore

/// Shared baseline policy for reusable in-memory and repository-backed setup.
struct ScenarioBaselineStartup {
    private struct Resolution {
        let definition: ScenarioDefinition
        let baselineAttachmentIDs: Set<AttachmentID>
        let diagnostics: [Diagnostic]
    }

    let layout: ScenarioDefinition
    let scenarioID: ScenarioID
    let defaultMode: ScenarioMode
    let systems: [AnyScenarioSystem]

    func start(
        baseline: ScenarioDefinition?, problem: ScenarioBaselineProblem = .missing,
        initialDiagnostics: [Diagnostic] = [])
        async throws(ScenarioStartupFailure) -> ScenarioExecution
    {
        let resolution = if let baseline {
            try resolve(baseline)
        } else {
            try resolveUnusable(problem)
        }
        return try await ScenarioExecution.start(
            definition: resolution.definition, scenarioID: scenarioID, defaultMode: defaultMode, systems: systems,
            baselineAttachmentIDs: resolution.baselineAttachmentIDs,
            initialDiagnostics: initialDiagnostics + resolution.diagnostics)
    }

    private func resolve(_ baseline: ScenarioDefinition)
        throws(ScenarioStartupFailure) -> Resolution
    {
        if let missing = layout.attachments.first(where: {
            effectiveMode(for: $0.id) == .replay && baseline.attachment(for: $0.id.key) == nil
        }) {
            throw failure(Diagnostic(issue: .baseline(.replayAttachmentMissing), context: .attachment(missing.id)))
        }
        let resolved: ScenarioDefinition
        do {
            resolved = try layout.replacingBaseline(with: baseline)
        } catch {
            return try resolveUnusable(.incompatibleSetup)
        }
        let keys = Set(layout.attachments.map(\.id.key))
        let diagnostics = baseline.attachments.compactMap { attachment -> Diagnostic? in
            guard !keys.contains(attachment.id.key) else { return nil }
            return Diagnostic(issue: .baseline(.loadedAttachmentNotConfigured), context: .attachment(attachment.id))
        }
        return Resolution(definition: resolved, baselineAttachmentIDs: Set(baseline.attachments.map(\.id)),
                          diagnostics: diagnostics)
    }

    private func resolveUnusable(_ problem: ScenarioBaselineProblem)
        throws(ScenarioStartupFailure) -> Resolution
    {
        if layout.attachments.contains(where: { effectiveMode(for: $0.id) == .replay }) {
            throw failure(Diagnostic(issue: .baseline(.requiredBaselineUnavailable(problem))))
        }
        let hasRecord = layout.attachments.contains { effectiveMode(for: $0.id) == .record }
        let diagnostics: [Diagnostic] = if hasRecord, problem != .missing {
            [Diagnostic(issue: .baseline(.baselineIgnoredForRecording(problem)))]
        } else {
            []
        }
        return Resolution(definition: layout.removingRecords(), baselineAttachmentIDs: [], diagnostics: diagnostics)
    }

    private func failure(_ diagnostic: Diagnostic) -> ScenarioStartupFailure {
        let reporter = DiagnosticReporter(scenarioID: scenarioID, definition: layout)
        reporter.record(diagnostic)
        return ScenarioStartupFailure(report: reporter.freeze())
    }

    private func effectiveMode(for id: AttachmentID) -> ScenarioMode {
        guard let system = systems.first(where: { $0.attachmentID == id }) else {
            preconditionFailure("Validated system registration is missing")
        }
        return system.effectiveMode(defaultMode: defaultMode)
    }
}
