import DioramaCore
import DioramaPersistence
import Foundation
import Synchronization

private enum DioramaExecutionState: Sendable {
    case idle(DioramaReport?)
    case executing
}

/// Sequentially reusable setup with shared reference identity and a final report.
///
/// Construction validates declarations without preparing systems or accessing
/// storage. Each start owns independent runtime state. System attachment values
/// supply layout only; recorded content comes exclusively from the selected baseline.
/// One instance admits one execution at a time; separate instances may run concurrently.
public final class Diorama<each Dependency: Sendable>: Sendable {
    private let systems: (repeat ScenarioSystem<each Dependency>)
    private let startup: @Sendable () throws -> DioramaRun
    private let state = Mutex<DioramaExecutionState>(.idle(nil))

    /// Safe completed evidence from the latest admitted execution attempt.
    ///
    /// Nil before execution, during an attempt, and after startup failure. A new
    /// admitted attempt clears the previous report; rejected overlapping calls
    /// leave it untouched. Body failure or cancellation still stores a report
    /// before the original error escapes. Retain this immutable value before
    /// starting another attempt; it contains no live dependencies or body error.
    public var report: DioramaReport? {
        state.withLock { state in
            switch state {
            case let .idle(report): report
            case .executing: nil
            }
        }
    }

    /// Creates in-memory setup without a baseline.
    ///
    /// Effective replay requires explicit content and therefore fails at start.
    /// - Parameters:
    ///   - scenarioID: Diagnostic identity for each run.
    ///   - mode: Mode inherited by systems without an override.
    ///   - systems: Active systems in dependency and activation order.
    /// - Throws: Invalid attachment identities.
    public convenience init(
        scenarioID: String, mode: ScenarioMode,
        systems: repeat ScenarioSystem<each Dependency>) throws
    {
        try self.init(baseline: nil, scenarioID: scenarioID, defaultMode: mode, systems: repeat each systems)
    }

    /// Creates setup with one fixed immutable baseline shared by independent runs.
    ///
    /// - Parameters:
    ///   - definition: Authoritative stable content, including explicitly empty tracks.
    ///   - scenarioID: Diagnostic identity for each run.
    ///   - mode: Mode inherited by systems without an override.
    ///   - systems: Active systems in dependency and activation order.
    /// - Throws: Invalid attachment identities.
    public convenience init(
        definition: ScenarioDefinition, scenarioID: String, mode: ScenarioMode,
        systems: repeat ScenarioSystem<each Dependency>) throws
    {
        try self.init(baseline: definition, scenarioID: scenarioID, defaultMode: mode,
                      systems: repeat each systems)
    }

    /// Creates reusable setup using a caller-configured JSON repository.
    ///
    /// This advanced path accepts custom document storage and explicit readers.
    /// Construction performs no I/O; each start validates registrations and loads
    /// once. Runs with an effective record attachment publish their complete
    /// healthy result at finalization, including after body failure or cancellation.
    /// Replay and passthrough alone never request publication.
    /// - Parameters:
    ///   - repository: Fixed codec and storage configuration, without cached content.
    ///   - scenarioID: Diagnostic identity for each run.
    ///   - mode: Mode inherited by systems without an override.
    ///   - systems: Active typed systems in dependency and activation order.
    /// - Throws: Invalid declarations.
    public convenience init(
        repository: JSONScenarioRepository, scenarioID: String, mode: ScenarioMode,
        systems: repeat ScenarioSystem<each Dependency>) throws
    {
        try self.init(systems: repeat each systems) { layout, registrations in
            try RepositoryStartup.start(repository: repository,
                                        scenarioID: ScenarioID(rawValue: scenarioID), defaultMode: mode,
                                        layout: layout, systems: registrations)
        }
    }

    /// Creates lazy file-backed setup using the configured systems' capabilities.
    ///
    /// Unknown persisted system types are diagnosed and discarded without payload
    /// decoding. Registered types still validate every instance before membership
    /// reconciliation. Construction performs no I/O.
    /// Healthy recording replaces the complete file at finalization. Encoding
    /// or storage failure preserves the resulting in-memory definition.
    /// - Parameters:
    ///   - file: Absolute local file URL for the scenario document.
    ///   - scenarioID: Diagnostic identity for each run.
    ///   - mode: Mode inherited by systems without an override.
    ///   - systems: Typed instances sharing system-wide persistence descriptors.
    /// - Throws: Invalid declarations, policy, conflicting types, or missing persistence.
    public convenience init(
        file: URL, scenarioID: String, mode: ScenarioMode,
        systems: repeat ScenarioSystem<each Dependency>) throws
    {
        guard file.isFileURL, file.baseURL == nil,
              file.host == nil || file.host == "",
              file.query == nil, file.fragment == nil,
              file.path.hasPrefix("/"), !file.hasDirectoryPath
        else {
            throw ScenarioFileLocationError.invalidRoot
        }
        let location = try ScenarioFileLocation(
            rootDirectory: file.deletingLastPathComponent(), relativePath: file.lastPathComponent)
        var types: [ScenarioSystemType] = []
        for system in repeat each systems {
            types.append(system.type)
        }
        let registry = try PersistentSystemRegistry(types)
        let repository = JSONScenarioRepository(
            codec: JSONScenarioCodec(registry: registry), storage: FileScenarioStorage(location: location))
        try self.init(repository: repository, scenarioID: scenarioID, mode: mode,
                      systems: repeat each systems)
    }

    private convenience init(
        baseline: ScenarioDefinition?, scenarioID: String, defaultMode: ScenarioMode,
        systems: repeat ScenarioSystem<each Dependency>) throws
    {
        try self.init(systems: repeat each systems) { layout, registrations in
            let startup = ScenarioBaselineStartup(
                layout: layout, scenarioID: ScenarioID(rawValue: scenarioID), defaultMode: defaultMode,
                systems: registrations)
            let execution = try startup.start(baseline: baseline)
            return DioramaRun(execution: execution)
        }
    }

    init(
        systems: repeat ScenarioSystem<each Dependency>,
        startup: @escaping @Sendable (ScenarioDefinition, [AnyScenarioSystem]) throws -> DioramaRun)
        throws
    {
        var attachments: [ScenarioAttachment] = []
        var registrations: [AnyScenarioSystem] = []
        for system in repeat each systems {
            attachments.append(system.attachment)
            registrations.append(AnyScenarioSystem(system))
        }
        let layout = try ScenarioDefinition(attachments: attachments).removingRecords()
        self.systems = (repeat each systems)
        let registered = registrations
        self.startup = { try startup(layout, registered) }
    }

    /// Runs a body with execution context and typed dependencies, then awaits finish.
    ///
    /// A body error is rethrown after finalization. Startup failure throws
    /// without invoking the body. The explicit isolation annotation
    /// preserves the caller's actor through the stored parameter pack.
    /// Overlapping or nested calls on this instance throw before startup; they
    /// are not queued. Admission covers rollback, finalization, and publication.
    /// The completed report is stored before returning or rethrowing a body error.
    /// - Parameters:
    ///   - body: Work receiving execution context followed by fresh dependencies
    ///     in declaration order, on its inferred actor. Context is available even
    ///     with no configured systems and creates no attachment or persisted values.
    /// - Returns: Successful body value, finalization, resulting definition,
    ///   publication disposition, and the exact load outcome. A failed publication
    ///   is reported without discarding the body value or healthy definition.
    /// - Throws: `DioramaExecutionError.executionAlreadyInProgress`, startup
    ///   failure, or the original body error after finalization and publication.
    public func execute<Success: Sendable, Failure: Error>(
        _ body: @isolated(any) (ScenarioExecutionContext, repeat each Dependency) async throws(Failure) -> Success)
        async throws -> DioramaResult<Success>
    {
        let admitted = state.withLock { state in
            guard case .idle = state else { return false }
            state = .executing
            return true
        }
        guard admitted else { throw DioramaExecutionError.executionAlreadyInProgress }
        var completedReport: DioramaReport?
        defer { state.withLock { $0 = .idle(completedReport) } }
        let run = try startup()
        let dependencies = (repeat run.requiredDependency(for: each systems))
        return try await run.runScoped(report: &completedReport) { () async throws(Failure) -> Success in
            try await body(run.context, repeat each dependencies)
        }
    }
}
