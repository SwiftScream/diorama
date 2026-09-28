import Synchronization

/// A safe, already-reported grouped-recording operation failure.
public struct GroupedLifecycleFailure: Error, Equatable, Sendable {
    /// The retained fact without captured values or native errors.
    public let diagnostic: Diagnostic
}

private final class InteractionPhaseOwner: Sendable {}

/// A phase identity scoped to one interaction; copies refer to the same phase.
public struct InteractionPhaseHandle: Sendable {
    fileprivate let owner: InteractionPhaseOwner
    fileprivate let index: Int
}

/// One execution-owned interaction recording under a reserved track position.
///
/// Every observed phase and terminal value is captured outside the state lock.
/// A reserved position survives slow conversion, while the recording horizon
/// concludes an active interaction explicitly as open.
public final class InteractionAccumulator<Input: Sendable, Observation: Sendable, Decision: Sendable,
    Output: Sendable, Failure: Sendable>: Sendable
{
    private enum Slot<Value: Sendable>: Sendable {
        case preparing
        case failed
        case value(LifecycleMoment<Value>)
    }

    private struct Phase: Sendable {
        var observation: Slot<Observation>
        var decision: Slot<Decision>?
    }

    private enum Terminal: Sendable {
        case preparing
        case invalid
        case returned(LifecycleMoment<Output>)
        case failed(LifecycleMoment<Failure>)
    }

    private struct State: Sendable {
        var input: Input?
        var phases: [Phase] = []
        var terminal: Terminal?
        var time: ExecutionTime?
        var frozen = false
    }

    /// The stable reserved track position for this interaction.
    public let identity: RecordIdentity

    private let beganAt: LogicalTimeCapture
    private let reporter: DiagnosticReporter
    private let owner = InteractionPhaseOwner()
    private let state: Mutex<State>

    /// Creates an accumulator for a stable input and validated start capture.
    init(identity: RecordIdentity, input: PreparedValue<Input>, beganAt: LogicalTimeCapture,
         time: ExecutionTime, reporter: DiagnosticReporter) throws(ExecutionTimeFailure)
    {
        _ = try time.logicalTime(at: beganAt)
        self.identity = identity
        self.beganAt = beganAt
        self.reporter = reporter
        state = Mutex(State(input: input.value, time: time))
    }

    /// Reserves a phase before stable extraction and returns its correlation.
    /// A failed capture invalidates the candidate without retaining the error.
    public func observe(at capture: LogicalTimeCapture, capturing value: () throws -> PreparedValue<Observation>)
        throws(GroupedLifecycleFailure) -> InteractionPhaseHandle
    {
        let offset = try relativeTime(at: capture)
        let reserved: Result<Int, GroupedLifecycleIssue> = state.withLock { state in
            if state.frozen {
                return .failure(.lateObservation)
            }
            if state.time?.isClosed != false {
                return .failure(.lateObservation)
            }
            if state.terminal != nil {
                return .failure(.afterConclusion)
            }
            let index = state.phases.endIndex
            state.phases.append(Phase(observation: .preparing))
            return .success(index)
        }
        let index = try accepted(reserved)
        let stable: PreparedValue<Observation>
        do { stable = try value() } catch {
            state.withLock { state in
                if !state.frozen {
                    state.phases[index].observation = .failed
                }
            }
            throw failure(.captureFailed)
        }
        let admitted = state.withLock { state in
            guard !state.frozen else { return false }
            state.phases[index].observation = .value(LifecycleMoment(validatedOffset: offset, value: stable.value))
            return true
        }
        guard admitted else { throw failure(.lateObservation, impact: .none) }
        return InteractionPhaseHandle(owner: owner, index: index)
    }

    /// Records one decision against its observed phase.
    public func respond(to phase: InteractionPhaseHandle, at capture: LogicalTimeCapture,
                        capturing value: () throws -> PreparedValue<Decision>) throws(GroupedLifecycleFailure)
    {
        let offset = try relativeTime(at: capture)
        let reserved: Result<Void, GroupedLifecycleIssue> = state.withLock { state in
            if state.frozen {
                return .failure(.lateObservation)
            }
            if state.time?.isClosed != false {
                return .failure(.lateObservation)
            }
            if state.terminal != nil {
                return .failure(.afterConclusion)
            }
            guard phase.owner === owner, state.phases.indices.contains(phase.index),
                  case let .value(observation) = state.phases[phase.index].observation
            else { return .failure(.unknownPhase) }
            guard state.phases[phase.index].decision == nil else { return .failure(.duplicateDecision) }
            guard offset >= observation.offset else { return .failure(.invalidTiming) }
            state.phases[phase.index].decision = .preparing
            return .success(())
        }
        try accepted(reserved)
        let stable: PreparedValue<Decision>
        do { stable = try value() } catch {
            state.withLock { state in
                if !state.frozen {
                    state.phases[phase.index].decision = .failed
                }
            }
            throw failure(.captureFailed)
        }
        let admitted = state.withLock { state in
            guard !state.frozen else { return false }
            state.phases[phase.index].decision = .value(LifecycleMoment(validatedOffset: offset, value: stable.value))
            return true
        }
        guard admitted else { throw failure(.lateObservation, impact: .none) }
    }

    /// Records a returned stable output as this interaction's only conclusion.
    public func returned(at capture: LogicalTimeCapture, capturing value: () throws -> PreparedValue<Output>)
        throws(GroupedLifecycleFailure)
    {
        let offset = try relativeTime(at: capture)
        try reserveTerminal()
        let stable: PreparedValue<Output>
        do { stable = try value() } catch {
            invalidateTerminal()
            throw failure(.captureFailed)
        }
        let admitted = state.withLock { state in
            guard !state.frozen else { return false }
            state.terminal = .returned(LifecycleMoment(validatedOffset: offset, value: stable.value))
            return true
        }
        guard admitted else { throw failure(.lateObservation, impact: .none) }
    }

    /// Records a stable dependency failure as the only conclusion.
    public func failed(at capture: LogicalTimeCapture, capturing value: () throws -> PreparedValue<Failure>)
        throws(GroupedLifecycleFailure)
    {
        let offset = try relativeTime(at: capture)
        try reserveTerminal()
        let stable: PreparedValue<Failure>
        do { stable = try value() } catch {
            invalidateTerminal()
            throw failure(.captureFailed)
        }
        let admitted = state.withLock { state in
            guard !state.frozen else { return false }
            state.terminal = .failed(LifecycleMoment(validatedOffset: offset, value: stable.value))
            return true
        }
        guard admitted else { throw failure(.lateObservation, impact: .none) }
    }

    private func reserveTerminal() throws(GroupedLifecycleFailure) {
        let reserved: Result<Void, GroupedLifecycleIssue> = state.withLock { state in
            if state.frozen {
                return .failure(.lateObservation)
            }
            if state.time?.isClosed != false {
                return .failure(.lateObservation)
            }
            guard state.terminal == nil else { return .failure(.duplicateConclusion) }
            state.terminal = .preparing
            return .success(())
        }
        try accepted(reserved)
    }

    private func invalidateTerminal() {
        state.withLock { state in
            if !state.frozen {
                state.terminal = .invalid
            }
        }
    }

    private func relativeTime(at capture: LogicalTimeCapture) throws(GroupedLifecycleFailure) -> Duration {
        guard let time = state.withLock({ $0.time }), !time.isClosed else {
            throw failure(.lateObservation, impact: .none)
        }
        do {
            return try time.elapsed(from: beganAt, to: capture)
        } catch {
            throw failure(.invalidTiming)
        }
    }

    private func accepted<T>(_ result: Result<T, GroupedLifecycleIssue>) throws(GroupedLifecycleFailure) -> T {
        switch result {
        case let .success(value): value
        case let .failure(issue):
            throw failure(issue, impact: issue == .lateObservation ? .none : .invalidatesCandidate)
        }
    }

    private func failure(_ issue: GroupedLifecycleIssue,
                         impact: RecordingImpact = .invalidatesCandidate) -> GroupedLifecycleFailure
    {
        let diagnostic = Diagnostic(issue: .sequential(.grouped(issue)), context: .record(identity),
                                    recordingImpact: impact)
        reporter.record(diagnostic)
        return GroupedLifecycleFailure(diagnostic: diagnostic)
    }

    /// Called once by the owning sequential lease at the recording horizon.
    func freeze() -> InteractionRecording<Input, Observation, Decision, Output, Failure>? {
        let detached = state.withLock { state in
            let detached = (state.input, state.phases, state.terminal)
            state.input = nil
            state.phases = []
            state.terminal = nil
            state.time = nil
            state.frozen = true
            return detached
        }
        guard let input = detached.0 else { return nil }
        var phases: [InteractionPhase<Observation, Decision>] = []
        for phase in detached.1 {
            guard case let .value(observation) = phase.observation else { return nil }
            let decision: LifecycleMoment<Decision>?
            if let slot = phase.decision {
                guard case let .value(value) = slot else { return nil }
                decision = value
            } else {
                decision = nil
            }
            guard let complete = try? InteractionPhase(observation: observation, decision: decision)
            else { return nil }
            phases.append(complete)
        }
        let conclusion: InteractionConclusion<Output, Failure>
        switch detached.2 {
        case let .returned(value): conclusion = .returned(value)
        case let .failed(value): conclusion = .failed(value)
        case .none: conclusion = .openAtRecordingHorizon
        case .preparing, .invalid: return nil
        }
        return try? InteractionRecording(input: input, phases: phases, conclusion: conclusion)
    }
}
