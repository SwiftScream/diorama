/// The behavior selected for a scenario or an entire system attachment.
public enum ScenarioMode: Hashable, Sendable {
    /// Observe live behavior and contribute records to the scenario.
    case record

    /// Supply behavior exclusively from scenario records.
    case replay

    /// Use live behavior without reading or changing scenario records.
    case passthrough
}
