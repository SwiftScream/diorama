import DioramaCore

/// Immutable completed evidence retained after success or an original body error.
///
/// Reports contain no body value, semantic definition, native dependency, or
/// arbitrary underlying error. Evaluation and rendering use the same frozen
/// facts. Text is generated only when explicitly requested.
public struct DioramaReport: Equatable, Sendable {
    /// Core diagnostics, usage, and attachment cleanup outcomes.
    public let finalization: ScenarioFinalizationFacts
    /// Safe publication outcomes, including candidate and prior-document evidence.
    public let publication: DioramaPublicationSummary

    /// Evaluates a caller-selected Core condition without changing the report.
    ///
    /// Publication outcomes remain separately inspectable through `publication`;
    /// these conditions do not turn publication issues into Core diagnostics.
    /// - Parameters:
    ///   - condition: The condition deliberately selected by the consumer.
    ///   - attachments: Selected attachment keys, or nil for the whole scenario.
    ///     An empty set selects no attachments; unknown keys produce failures.
    /// - Returns: Ordered safe evidence and satisfaction of the condition.
    public func evaluated(_ condition: ScenarioEvaluationCondition,
                          attachments: Set<AttachmentKey>? = nil) -> ScenarioEvaluation
    {
        finalization.evaluated(condition, attachments: attachments)
    }

    /// Renders deterministic text from the completed facts on demand.
    /// - Returns: Safe finalization and publication evidence in report order.
    public func rendered() -> String {
        finalization.rendered() + "\n" + publication.rendered(scenarioID: finalization.report.scenarioID)
    }
}
