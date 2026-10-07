/// Execution-wide services shared by application code during one scenario run.
///
/// Obtain this value from ``ScenarioExecution/context`` or the scoped Diorama
/// body. Retaining it does not extend execution lifetime or keep adapters alive.
/// Its services retain their individual closed-execution behavior after finish.
public struct ScenarioExecutionContext: Sendable {
    /// The execution's shared monotonic clock, independent of system attachments.
    /// Reads and sleeps create no recorded values or usage counts.
    public let clock: ScenarioClock
}
