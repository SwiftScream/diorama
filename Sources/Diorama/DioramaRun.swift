import DioramaCore
import DioramaPersistence

/// Internal execution state used by the scoped consumer operation.
struct DioramaRun: Sendable {
    private let execution: ScenarioExecution
    private let repository: JSONScenarioRepository?

    /// The exact repository load outcome, or nil for an in-memory baseline.
    let loadResult: ScenarioLoadResult?

    var context: ScenarioExecutionContext {
        execution.context
    }

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

    func finish<Success: Sendable>(
        bodyResult: Result<Success, some Error>, report: inout DioramaReport?) async throws -> DioramaResult<Success>
    {
        let finalization = await execution.finish()
        let publication = Self.publish(finalization.definition, to: repository)
        let completedReport = DioramaReport(
            finalization: finalization.facts,
            publication: DioramaPublicationSummary(finalization: finalization,
                                                   publication: publication, loadResult: loadResult))
        report = completedReport
        let value = try bodyResult.get()
        return DioramaResult(body: value, report: completedReport, definition: finalization.definition,
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

/// A successful body value, shared report, and explicit caller-owned output.
/// Body values and detailed errors may themselves retain application resources.
public struct DioramaResult<Success: Sendable>: Sendable {
    /// The body's successfully returned value.
    public let body: Success

    /// The same safe completed evidence retained by the setup after either body outcome.
    public let report: DioramaReport

    /// Complete healthy semantic output, independently of encoding or storage success.
    /// Retaining this result explicitly retains its output payloads; the report does not.
    public let definition: ScenarioDefinition?

    /// The exact repository load outcome, including a loaded baseline or underlying error.
    public let loadResult: ScenarioLoadResult?

    /// Detailed optional publication, including underlying encoding or storage errors.
    public let publication: DioramaPublication
}
