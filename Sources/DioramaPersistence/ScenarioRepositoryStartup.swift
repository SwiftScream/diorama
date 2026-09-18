import DioramaCore

/// A running execution together with the exact repository load result used to
/// configure it.
///
/// The retained result supplies the immutable baseline needed by later
/// candidate construction. Runtime replay claims never mutate that value.
public struct RepositoryScenarioExecution: Sendable {
    /// The fully prepared and activated runtime execution.
    public let execution: ScenarioExecution

    /// The one load result observed before any system callback.
    public let loadResult: ScenarioLoadResult
}

/// Exact repository evidence retained when startup returns no execution.
public enum ScenarioRepositoryStartupEvidence: Sendable {
    /// Runtime setup lacks a required persistent-system registration; storage
    /// was not read.
    case persistenceConfiguration(PersistenceDispatchError)

    /// Storage was read once and produced this exact result.
    case load(ScenarioLoadResult)
}

/// A repository-backed startup failure with safe lifecycle diagnostics and the
/// exact persistence evidence that preceded them.
public struct ScenarioRepositoryStartupFailure: Error, Sendable {
    /// The persistence result or pre-load configuration failure.
    public let evidence: ScenarioRepositoryStartupEvidence

    /// Safe diagnostic and rollback evidence; no execution escaped.
    public let startupFailure: ScenarioStartupFailure
}

private struct RepositoryStartupContext: Sendable {
    let setup: ScenarioDefinition
    let loadResult: ScenarioLoadResult
    let hasReplay: Bool
    let hasRecord: Bool
    let sink: DiagnosticSink?

    init(setup: ScenarioDefinition, loadResult: ScenarioLoadResult, sink: DiagnosticSink?) {
        self.setup = setup
        self.loadResult = loadResult
        hasReplay = setup.attachments.contains {
            ($0.modeOverride ?? setup.defaultMode) == .replay
        }
        hasRecord = setup.attachments.contains {
            ($0.modeOverride ?? setup.defaultMode) == .record
        }
        self.sink = sink
    }

    var evidence: ScenarioRepositoryStartupEvidence {
        .load(loadResult)
    }
}

private struct RepositoryStartupResolution: Sendable {
    let definition: ScenarioDefinition
    let diagnostics: [Diagnostic]
}

public extension JSONScenarioRepository {
    /// Loads one authoritative baseline and starts an execution only after its
    /// effective-mode requirements are satisfied.
    ///
    /// This is the repository-backed counterpart to the programmatic
    /// ``DioramaCore/ScenarioExecution/start(definition:systems:initialDiagnostics:sink:)``
    /// path. The setup definition contributes scenario identity, modes,
    /// attachment layout, and ignored keys. Matching loaded attachments supply
    /// stable content and are prepared again under current system policy before
    /// any activation. Loaded attachments absent from setup are diagnosed and
    /// discarded from the resolved definition.
    ///
    /// Any replay attachment requires a usable loaded attachment. Record mode
    /// may rebuild from missing or unusable storage; nonmissing unusable input
    /// records a safe warning that authored overrides and unchanged tracks
    /// cannot be preserved. Passthrough does not require baseline content.
    /// Startup never publishes or otherwise writes the repository.
    ///
    /// - Parameters:
    ///   - setup: Immutable runtime configuration. Its record content is not a
    ///     fallback for this explicitly repository-backed path.
    ///   - systems: Exactly one runtime registration per configured attachment.
    ///   - sink: Optional safe diagnostic notification for this run.
    /// - Returns: A running execution and the exact retained load result.
    /// - Throws: Configuration, load-policy, preparation, activation, or
    ///   rollback evidence. No partially active execution escapes.
    func start(
        configuredBy setup: ScenarioDefinition,
        systems: [AnyScenarioSystem],
        sink: DiagnosticSink? = nil) throws(ScenarioRepositoryStartupFailure) -> RepositoryScenarioExecution
    {
        do {
            try validatePersistability(of: setup)
        } catch {
            let diagnostic = Diagnostic(issue: .baseline(.invalidPersistenceConfiguration))
            throw startupFailure(
                definition: setup,
                diagnostic: diagnostic,
                evidence: .persistenceConfiguration(error),
                sink: sink)
        }

        let loadResult = load()
        let resolution = try resolve(RepositoryStartupContext(
            setup: setup,
            loadResult: loadResult,
            sink: sink))

        do {
            let execution = try ScenarioExecution.start(
                definition: resolution.definition,
                systems: systems,
                initialDiagnostics: resolution.diagnostics,
                sink: sink)
            return RepositoryScenarioExecution(execution: execution, loadResult: loadResult)
        } catch {
            throw ScenarioRepositoryStartupFailure(
                evidence: .load(loadResult),
                startupFailure: error)
        }
    }

    private func resolve(_ context: RepositoryStartupContext)
        throws(ScenarioRepositoryStartupFailure) -> RepositoryStartupResolution
    {
        switch context.loadResult {
        case let .loaded(baseline):
            try resolveLoaded(baseline, context: context)
        case .missing:
            try resolveUnusable(.missing, context: context)
        case .unreadable:
            try resolveUnusable(.unreadable, context: context)
        case .invalidDocument:
            try resolveUnusable(.invalidDocument, context: context)
        case .incompatibleEnvelope:
            try resolveUnusable(.incompatibleEnvelope, context: context)
        case .incompatibleSystem:
            try resolveUnusable(.incompatibleSystem, context: context)
        }
    }

    private func resolveLoaded(
        _ baseline: PersistedScenario,
        context: RepositoryStartupContext) throws(ScenarioRepositoryStartupFailure) -> RepositoryStartupResolution
    {
        if let missing = context.setup.attachments.first(where: { attachment in
            (attachment.modeOverride ?? context.setup.defaultMode) == .replay &&
                !baseline.attachments.contains(where: { $0.id.key == attachment.id.key })
        }) {
            throw startupFailure(
                definition: context.setup,
                diagnostic: Diagnostic(
                    issue: .baseline(.replayAttachmentMissing),
                    context: .attachment(missing.id)),
                evidence: context.evidence,
                sink: context.sink)
        }
        do {
            let configuredKeys = Set(context.setup.attachments.map(\.id.key))
            let diagnostics = baseline.attachments.compactMap { attachment -> Diagnostic? in
                guard !configuredKeys.contains(attachment.id.key) else { return nil }
                return Diagnostic(
                    issue: .baseline(.loadedAttachmentNotConfigured),
                    context: .attachment(attachment.id))
            }
            return try RepositoryStartupResolution(
                definition: context.setup.replacingBaseline(with: baseline.attachments),
                diagnostics: diagnostics)
        } catch {
            return try resolveUnusable(.incompatibleSetup, context: context)
        }
    }

    private func resolveUnusable(
        _ problem: ScenarioBaselineProblem,
        context: RepositoryStartupContext) throws(ScenarioRepositoryStartupFailure) -> RepositoryStartupResolution
    {
        if context.hasReplay {
            throw startupFailure(
                definition: context.setup,
                diagnostic: Diagnostic(issue: .baseline(.requiredBaselineUnavailable(problem))),
                evidence: context.evidence,
                sink: context.sink)
        }
        let definition: ScenarioDefinition
        do {
            definition = try context.setup.removingBaseline()
        } catch {
            throw definitionFailure(
                definition: context.setup,
                evidence: context.evidence,
                sink: context.sink)
        }
        let diagnostics: [Diagnostic] = if context.hasRecord, problem != .missing {
            [Diagnostic(issue: .baseline(.baselineIgnoredForRecording(problem)))]
        } else {
            []
        }
        return RepositoryStartupResolution(definition: definition, diagnostics: diagnostics)
    }

    private func definitionFailure(
        definition: ScenarioDefinition,
        evidence: ScenarioRepositoryStartupEvidence,
        sink: DiagnosticSink?) -> ScenarioRepositoryStartupFailure
    {
        startupFailure(
            definition: definition,
            diagnostic: Diagnostic(issue: .baseline(.requiredBaselineUnavailable(.incompatibleSetup))),
            evidence: evidence,
            sink: sink)
    }

    private func startupFailure(
        definition: ScenarioDefinition,
        diagnostic: Diagnostic,
        evidence: ScenarioRepositoryStartupEvidence,
        sink: DiagnosticSink?) -> ScenarioRepositoryStartupFailure
    {
        let reporter = DiagnosticReporter(definition: definition, sink: sink)
        reporter.record(diagnostic)
        return ScenarioRepositoryStartupFailure(
            evidence: evidence,
            startupFailure: ScenarioStartupFailure(report: reporter.report))
    }
}
