/// Invalid timing or phase order in an immutable grouped recording.
public enum GroupedLifecycleValidationIssue: Error, Equatable, Sendable {
    /// An observation precedes its group's start.
    case negativeOffset
    /// A later listed observation precedes an earlier one.
    case eventOrder
    /// A response precedes the phase it answers.
    case decisionBeforeObservation
    /// A terminal conclusion precedes an observed phase or event.
    case conclusionBeforeObservation
}

/// A stable value at a nonnegative offset from its group's start.
public struct LifecycleMoment<Value: Sendable>: Sendable {
    /// Relative logical time; no host instant enters the recording.
    public let offset: Duration
    /// The system's stable semantic value.
    public let value: Value

    /// Creates a moment after validating its relative offset.
    public init(offset: Duration, value: Value) throws(GroupedLifecycleValidationIssue) {
        guard offset >= .zero else { throw .negativeOffset }
        self.offset = offset
        self.value = value
    }

    init(validatedOffset: Duration, value: Value) {
        offset = validatedOffset
        self.value = value
    }
}

/// One observed interaction phase and its optional correlated decision.
public struct InteractionPhase<Observation: Sendable, Decision: Sendable>: Sendable {
    /// The observed phase.
    public let observation: LifecycleMoment<Observation>
    /// The response to this phase, when the caller supplied one.
    public let decision: LifecycleMoment<Decision>?

    /// Creates one phase, rejecting a decision before its observation.
    public init(observation: LifecycleMoment<Observation>, decision: LifecycleMoment<Decision>? = nil)
        throws(GroupedLifecycleValidationIssue)
    {
        if let decision, decision.offset < observation.offset {
            throw .decisionBeforeObservation
        }
        self.observation = observation
        self.decision = decision
    }
}

/// Exactly one conclusion for a recorded interaction.
public enum InteractionConclusion<Output: Sendable, Failure: Sendable>: Sendable {
    /// The operation returned its stable output.
    case returned(LifecycleMoment<Output>)
    /// The operation failed with a stable dependency failure.
    case failed(LifecycleMoment<Failure>)
    /// Recording ended while the operation was still active.
    case openAtRecordingHorizon

    var offset: Duration? {
        switch self {
        case let .returned(moment): moment.offset
        case let .failed(moment): moment.offset
        case .openAtRecordingHorizon: nil
        }
    }
}

/// One immutable interaction, correlated by its enclosing track record.
public struct InteractionRecording<Input: Sendable, Observation: Sendable, Decision: Sendable,
    Output: Sendable, Failure: Sendable>: Sendable
{
    /// Stable input observed at the group's start.
    public let input: Input
    /// Phases in observation order; decisions remain attached to their phase.
    public let phases: [InteractionPhase<Observation, Decision>]
    /// One returned, failed, or explicitly open outcome.
    public let conclusion: InteractionConclusion<Output, Failure>

    /// Validates complete phase and conclusion order before admission.
    public init(input: Input, phases: [InteractionPhase<Observation, Decision>],
                conclusion: InteractionConclusion<Output, Failure>) throws(GroupedLifecycleValidationIssue)
    {
        var previousObservation: Duration = .zero
        var latest: Duration = .zero
        for phase in phases {
            guard phase.observation.offset >= previousObservation else { throw .eventOrder }
            previousObservation = phase.observation.offset
            latest = max(latest, phase.decision?.offset ?? phase.observation.offset)
        }
        if let terminal = conclusion.offset, terminal < latest {
            throw .conclusionBeforeObservation
        }
        self.input = input
        self.phases = phases
        self.conclusion = conclusion
    }
}

extension LifecycleMoment: Equatable where Value: Equatable {}
extension InteractionPhase: Equatable where Observation: Equatable, Decision: Equatable {}
extension InteractionConclusion: Equatable where Output: Equatable, Failure: Equatable {}
extension InteractionRecording: Equatable where Input: Equatable, Observation: Equatable,
    Decision: Equatable, Output: Equatable, Failure: Equatable {}
