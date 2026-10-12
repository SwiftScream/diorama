/// Consumer execution admission failures, independent of an active run's diagnostics.
public enum DioramaExecutionError: Error, Equatable, Sendable {
    /// This instance is already starting, running, finalizing, or publishing a run.
    /// The rejected attempt performs no startup work and does not invoke its body.
    case executionAlreadyInProgress
}
