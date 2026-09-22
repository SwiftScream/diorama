import DioramaCore
import DioramaPersistence
import Foundation

/// Complete reusable setup retaining a heterogeneous, statically typed system list.
///
/// Construction validates declarations without preparing systems or accessing
/// storage. Each start owns independent runtime state. System attachment values
/// supply layout only; recorded content comes exclusively from the selected baseline.
public struct Diorama<each Dependency: Sendable>: Sendable {
    private let systems: (repeat ScenarioSystem<each Dependency>)
    private let startup: @Sendable () throws -> DioramaRun

    /// Creates in-memory setup without a baseline.
    ///
    /// Effective replay requires explicit content and therefore fails at start.
    /// - Parameters:
    ///   - scenarioID: Diagnostic identity for each run.
    ///   - mode: Mode inherited by systems without an override.
    ///   - systems: Active systems in dependency and activation order.
    /// - Throws: Invalid attachment identities.
    public init(
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
    public init(
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
    public init(
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
    public init(
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

    private init(
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

    /// Runs a body with typed dependencies in declaration order, then awaits finish.
    ///
    /// A body error is rethrown after finalization. Startup failure throws
    /// without invoking the body. The explicit isolation annotation
    /// preserves the caller's actor through the stored parameter pack.
    /// - Parameters:
    ///   - body: Work receiving fresh dependencies on its inferred actor.
    /// - Returns: Successful body value, finalization, resulting definition,
    ///   publication disposition, and the exact load outcome. A failed publication
    ///   is reported without discarding the body value or healthy definition.
    /// - Throws: Startup or body failure, after finalization when the body throws.
    public func execute<Success: Sendable, Failure: Error>(
        _ body: @isolated(any) (repeat each Dependency) async throws(Failure) -> Success)
        async throws -> DioramaResult<Success>
    {
        let run = try startup()
        let dependencies = (repeat run.requiredDependency(for: each systems))
        return try await run.runScoped { () async throws(Failure) -> Success in
            try await body(repeat each dependencies)
        }
    }
}
