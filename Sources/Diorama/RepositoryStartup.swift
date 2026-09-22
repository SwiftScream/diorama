import DioramaCore
import DioramaPersistence

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

enum RepositoryStartup {
    /// Loads one authoritative baseline and starts an execution only after its
    /// effective-mode requirements are satisfied.
    ///
    /// This is the repository-backed counterpart to the programmatic
    /// ``DioramaCore/ScenarioExecution/start(definition:scenarioID:defaultMode:systems:initialDiagnostics:sink:)``
    /// path. Diorama construction has already validated the active layout.
    /// Setup supplies identity and the default mode; system instances supply
    /// overrides and unused-record policy. The setup definition supplies
    /// only the active attachment layout. Matching
    /// loaded attachments supply stable content and are validated under current system policy before
    /// any activation. Loaded attachments absent from setup are diagnosed and
    /// discarded from the resolved definition.
    /// Unregistered system types retain their headers but skip payload decoding.
    /// Registered types validate every instance, including inactive keys.
    /// A skipped header at a configured key makes the baseline incompatible.
    ///
    /// Any replay attachment requires a usable loaded attachment. Record mode
    /// may rebuild from missing or unusable storage; nonmissing unusable input
    /// records a safe warning that authored overrides and unchanged tracks
    /// cannot be preserved. Passthrough does not require baseline content.
    /// Startup never publishes or otherwise writes the repository.
    ///
    /// - Parameters:
    ///   - repository: Codec and storage for the selected baseline.
    ///   - scenarioID: Diagnostic identity for this run.
    ///   - defaultMode: Mode inherited by systems without an override.
    ///   - setup: Active typed layout. Its record content is not a fallback
    ///     for this explicitly repository-backed path.
    ///   - systems: Exactly one runtime registration per configured attachment.
    /// - Returns: A running execution and the exact retained load result.
    /// - Throws: Persistence configuration, load-policy, preparation, activation, or
    ///   rollback evidence. No partially active execution escapes.
    static func start(
        repository: JSONScenarioRepository,
        scenarioID: ScenarioID,
        defaultMode: ScenarioMode,
        layout setup: ScenarioDefinition,
        systems: [AnyScenarioSystem]) throws(ScenarioRepositoryStartupFailure) -> DioramaRun
    {
        do {
            try repository.validatePersistability(of: setup)
        } catch {
            let diagnostic = Diagnostic(issue: .baseline(.invalidPersistenceConfiguration))
            throw startupFailure(
                definition: setup, scenarioID: scenarioID,
                diagnostic: diagnostic,
                evidence: .persistenceConfiguration(error))
        }

        let loadResult = repository.load(unknownSystems: .discard)
        let skipped = loadResult.skippedSystems
        let activeKeys = Set(setup.attachments.map(\.id.key))
        let incompatible = skipped.contains { activeKeys.contains($0.attachmentKey) }
        let diagnostics = skipped.filter { !activeKeys.contains($0.attachmentKey) }.map {
            Diagnostic(issue: .baseline(.loadedAttachmentNotConfigured), context: .attachment($0.attachmentID))
        }
        do {
            let startup = ScenarioBaselineStartup(
                layout: setup, scenarioID: scenarioID, defaultMode: defaultMode,
                systems: systems)
            let execution = try startup.start(
                baseline: incompatible ? nil : loadResult.baseline,
                problem: incompatible ? .incompatibleSetup : loadResult.problem,
                initialDiagnostics: diagnostics)
            return DioramaRun(execution: execution, loadResult: loadResult)
        } catch {
            throw ScenarioRepositoryStartupFailure(
                evidence: .load(loadResult),
                startupFailure: error)
        }
    }

    private static func startupFailure(
        definition: ScenarioDefinition, scenarioID: ScenarioID,
        diagnostic: Diagnostic,
        evidence: ScenarioRepositoryStartupEvidence) -> ScenarioRepositoryStartupFailure
    {
        let reporter = DiagnosticReporter(scenarioID: scenarioID, definition: definition)
        reporter.record(diagnostic)
        return ScenarioRepositoryStartupFailure(
            evidence: evidence,
            startupFailure: ScenarioStartupFailure(report: reporter.report))
    }
}

private extension ScenarioLoadResult {
    var baseline: ScenarioDefinition? {
        if case let .loaded(definition, _) = self {
            return definition
        }
        return nil
    }

    var skippedSystems: [PersistedSystemDescriptor] {
        if case let .loaded(_, skipped) = self {
            return skipped
        }
        return []
    }

    var problem: ScenarioBaselineProblem {
        switch self {
        case .loaded, .missing: .missing
        case .unreadable: .unreadable
        case .invalidDocument: .invalidDocument
        case .incompatibleEnvelope: .incompatibleEnvelope
        case .incompatibleSystem: .incompatibleSystem
        }
    }
}
