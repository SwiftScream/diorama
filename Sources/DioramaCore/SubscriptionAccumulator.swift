import Synchronization

/// One execution-owned subscription recording under a reserved track position.
///
/// Deliveries and nonterminal failures retain their observation order. The
/// recording horizon concludes a still-active subscription explicitly as open.
public final class SubscriptionAccumulator<Input: Sendable, Value: Sendable, Failure: Sendable>: Sendable {
    private enum EventSlot: Sendable {
        case preparing
        case invalid
        case value(SubscriptionEvent<Value, Failure>)
    }

    private enum Terminal: Sendable {
        case preparing
        case invalid
        case finished(Duration?)
        case failed(LifecycleMoment<Failure>)
    }

    private struct State: Sendable {
        var input: Input?
        var events: [EventSlot] = []
        var terminal: Terminal?
        var time: ExecutionTime?
        var frozen = false
    }

    /// The stable reserved track position for this subscription.
    public let identity: RecordIdentity

    private let beganAt: LogicalTimeCapture
    private let reporter: DiagnosticReporter
    private let state: Mutex<State>

    /// Creates an accumulator for stable input and a validated start capture.
    init(identity: RecordIdentity, input: PreparedValue<Input>, beganAt: LogicalTimeCapture,
         time: ExecutionTime, reporter: DiagnosticReporter) throws(ExecutionTimeFailure)
    {
        _ = try time.logicalTime(at: beganAt)
        self.identity = identity
        self.beganAt = beganAt
        self.reporter = reporter
        state = Mutex(State(input: input.value, time: time))
    }

    /// Reserves an emission before extracting its stable value.
    public func deliver(at capture: LogicalTimeCapture, capturing value: () throws -> PreparedValue<Value>)
        throws(GroupedLifecycleFailure)
    {
        let offset = try relativeTime(at: capture)
        let index = try reserveEvent()
        let stable: PreparedValue<Value>
        do { stable = try value() } catch {
            invalidateEvent(at: index)
            throw failure(.captureFailed)
        }
        let event = SubscriptionEvent<Value, Failure>.delivered(
            LifecycleMoment(validatedOffset: offset, value: stable.value))
        try admit(event, at: index)
    }

    /// Records a dependency failure that permits later deliveries.
    public func reportNonterminalFailure(at capture: LogicalTimeCapture,
                                         capturing value: () throws -> PreparedValue<Failure>)
        throws(GroupedLifecycleFailure)
    {
        let offset = try relativeTime(at: capture)
        let index = try reserveEvent()
        let stable: PreparedValue<Failure>
        do { stable = try value() } catch {
            invalidateEvent(at: index)
            throw failure(.captureFailed)
        }
        let event = SubscriptionEvent<Value, Failure>.reported(
            LifecycleMoment(validatedOffset: offset, value: stable.value))
        try admit(event, at: index)
    }

    /// Finishes normally, optionally recording its relative completion time.
    public func finish(at capture: LogicalTimeCapture? = nil) throws(GroupedLifecycleFailure) {
        let offset: Duration? = if let capture {
            try relativeTime(at: capture)
        } else {
            nil
        }
        try reserveTerminal()
        let admitted = state.withLock { state in
            guard !state.frozen else { return false }
            state.terminal = .finished(offset)
            return true
        }
        guard admitted else { throw failure(.lateObservation, impact: .none) }
    }

    /// Records a stable terminal dependency failure.
    public func fail(at capture: LogicalTimeCapture, capturing value: () throws -> PreparedValue<Failure>)
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

    private func reserveEvent() throws(GroupedLifecycleFailure) -> Int {
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
            let index = state.events.endIndex
            state.events.append(.preparing)
            return .success(index)
        }
        return try accepted(reserved)
    }

    private func invalidateEvent(at index: Int) {
        state.withLock { state in
            if !state.frozen {
                state.events[index] = .invalid
            }
        }
    }

    private func admit(_ event: SubscriptionEvent<Value, Failure>, at index: Int)
        throws(GroupedLifecycleFailure)
    {
        let admitted = state.withLock { state in
            guard !state.frozen else { return false }
            state.events[index] = .value(event)
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
    func freeze() -> SubscriptionRecording<Input, Value, Failure>? {
        let detached = state.withLock { state in
            let detached = (state.input, state.events, state.terminal)
            state.input = nil
            state.events = []
            state.terminal = nil
            state.time = nil
            state.frozen = true
            return detached
        }
        guard let input = detached.0 else { return nil }
        var events: [SubscriptionEvent<Value, Failure>] = []
        for slot in detached.1 {
            guard case let .value(event) = slot else { return nil }
            events.append(event)
        }
        let conclusion: SubscriptionConclusion<Failure>
        switch detached.2 {
        case let .finished(offset): conclusion = .finished(atTime: offset)
        case let .failed(value): conclusion = .failed(value)
        case .none: conclusion = .openAtRecordingHorizon
        case .preparing, .invalid: return nil
        }
        return try? SubscriptionRecording(input: input, events: events, conclusion: conclusion)
    }
}
