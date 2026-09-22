import DioramaPersistence

/// The outcome of optional whole-scenario publication after core finalization.
///
/// Underlying errors and cleanup evidence are explicit caller-owned data. They
/// are never automatically rendered or treated as test outcomes.
public enum DioramaPublication: Sendable {
    /// In-memory execution, or no configured attachment ran in record mode.
    case notRequested

    /// Recording could not produce a complete healthy semantic definition.
    case refusedUnhealthy

    /// The complete document committed, with any subsequent storage cleanup evidence.
    case published(DocumentPublication)

    /// Encoding or storage failed before commit; the healthy definition remains available.
    case failed(ScenarioPublicationError)
}
