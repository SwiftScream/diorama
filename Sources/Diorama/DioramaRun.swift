import DioramaCore
import DioramaPersistence

/// Internal execution state used by the scoped consumer operation.
struct DioramaRun: Sendable {
    private let execution: ScenarioExecution

    /// The exact repository load outcome, or nil for an in-memory baseline.
    let loadResult: ScenarioLoadResult?

    init(execution: ScenarioExecution, loadResult: ScenarioLoadResult? = nil) {
        self.execution = execution
        self.loadResult = loadResult
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
        let value = try bodyResult.get()
        return DioramaResult(body: value, finalization: finalization, loadResult: loadResult)
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
}
