import DioramaCore
import DioramaPersistence

/// Internal execution state used by the scoped consumer operation.
struct DioramaRun: Sendable {
    private let execution: ScenarioExecution
    private let repository: JSONScenarioRepository?

    /// The exact repository load outcome, or nil for an in-memory baseline.
    let loadResult: ScenarioLoadResult?

    init(execution: ScenarioExecution, loadResult: ScenarioLoadResult? = nil,
         repository: JSONScenarioRepository? = nil)
    {
        self.execution = execution
        self.loadResult = loadResult
        self.repository = repository
    }

    func requiredDependency<Dependency: Sendable>(for system: ScenarioSystem<Dependency>) -> Dependency {
        do {
            return try execution.dependency(system)
        } catch {
            preconditionFailure("A freshly started run must contain every configured dependency")
        }
    }

    func runScoped<Success: Sendable, Failure: Error>(
        _ body: () async throws(Failure) -> Success) async throws -> DioramaResult<Success>
    {
        let bodyResult: Result<Success, Failure>
        do {
            bodyResult = try await .success(body())
        } catch {
            bodyResult = .failure(error)
        }
        let finalization = await execution.finish()
        let publication = Self.publish(finalization.definition, to: repository)
        let value = try bodyResult.get()
        return DioramaResult(body: value, finalization: finalization,
                             loadResult: loadResult, publication: publication)
    }

    private static func publish(_ definition: ScenarioDefinition?, to repository: JSONScenarioRepository?)
        -> DioramaPublication
    {
        guard let repository else { return .notRequested }
        guard let definition else { return .refusedUnhealthy }
        do {
            return try .published(repository.publish(definition))
        } catch {
            return .failed(error)
        }
    }
}

/// A successful scoped body value and completed run evidence, without retained adapters.
public struct DioramaResult<Success: Sendable>: Sendable {
    /// The body's successfully returned value.
    public let body: Success

    /// Immutable lifecycle, usage, and diagnostic evidence after cleanup.
    public let finalization: ScenarioFinalizationResult

    /// The exact repository load outcome, or nil for an in-memory baseline.
    public let loadResult: ScenarioLoadResult?

    /// Complete healthy semantic output, independently of encoding or storage success.
    public var definition: ScenarioDefinition? {
        finalization.definition
    }

    /// Optional repository publication, independently of the body's successful value.
    public let publication: DioramaPublication

    /// Safe aggregate of finalization and publication facts, computed on demand
    /// without inspecting payloads or rendering arbitrary errors.
    public var report: DioramaReport {
        DioramaReport(finalization: finalization, publication: publication, loadResult: loadResult)
    }
}
