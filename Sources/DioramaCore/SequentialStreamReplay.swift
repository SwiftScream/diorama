import Synchronization

public extension SequentialTrackLease {
    /// Selects and replays one subscription with a private timing anchor.
    ///
    /// The stable input is already prepared by the owning system. A successful
    /// claim stays used if later deadline registration fails.
    func replaySubscription<SelectionInput: Sendable, Input: Sendable, Element: Sendable, Failure: Sendable>(
        matching input: SelectionInput,
        using selector: GroupedReplaySelector<SelectionInput, Value>,
        time: ExecutionTime,
        scheduling: SchedulingLease,
        deliver: @escaping @Sendable (StreamReplayDelivery<Element, Failure>) async -> Void)
        throws -> StreamReplaySubscription<Input, Element, Failure>
        where Value == SubscriptionRecording<Input, Element, Failure>
    {
        let anchor = try time.capture()
        let claim = try claimGrouped(matching: input, using: selector)
        return try StreamReplaySubscription.start(claim: claim, anchor: anchor, time: time,
                                                  scheduling: scheduling, deliver: deliver)
    }
}

/// One event presented by a replayed subscription.
public enum StreamReplayDelivery<Value: Sendable, Failure: Sendable>: Sendable {
    /// A stable value published by the dependency.
    case value(Value)
    /// A dependency failure after which the subscription continues.
    case nonterminalFailure(Failure)
    /// The subscription finished normally.
    case finished
    /// The subscription ended with a stable dependency failure.
    case failed(Failure)
}

/// Cancellation and lifetime for one selected replay subscription.
///
/// Delivery is serial within this subscription, including equal-offset events.
/// Canceling prevents later deliveries without returning the claimed group to
/// availability. A delivery already running may finish before cancellation.
public final class StreamReplaySubscription<Input: Sendable, Value: Sendable, Failure: Sendable>: Sendable {
    private struct Step: Sendable {
        let deadline: Duration
        let delivery: StreamReplayDelivery<Value, Failure>
        let terminal: Bool
    }

    private struct Activity: Sendable {
        let claim: GroupedReplayClaim<SubscriptionRecording<Input, Value, Failure>>
        let scheduling: SchedulingLease
        let steps: [Step]
        let deliver: @Sendable (StreamReplayDelivery<Value, Failure>) async -> Void
    }

    private enum Phase: Sendable {
        case registering(Int)
        case pending(Int)
        case delivering(Int)
        case open
        case completed
        case canceled
    }

    private struct State: Sendable {
        var phase: Phase
        var pending: ScheduledItemHandle?
    }

    private let state: Mutex<State>

    private init(hasSteps: Bool, open: Bool) {
        let phase: Phase = !hasSteps && open ? .open : .registering(0)
        state = Mutex(State(phase: phase))
    }

    static func start(
        claim: GroupedReplayClaim<SubscriptionRecording<Input, Value, Failure>>,
        anchor: LogicalTimeCapture, time: ExecutionTime, scheduling: SchedulingLease,
        deliver: @escaping @Sendable (StreamReplayDelivery<Value, Failure>) async -> Void)
        throws -> StreamReplaySubscription<Input, Value, Failure>
    {
        let recording = claim.record.value
        var steps: [Step] = []
        for event in recording.events {
            let delivery: StreamReplayDelivery<Value, Failure> = switch event {
            case let .delivered(moment): .value(moment.value)
            case let .reported(moment): .nonterminalFailure(moment.value)
            }
            let deadline = try time.logicalTime(after: event.offset, from: anchor)
            steps.append(Step(deadline: deadline, delivery: delivery, terminal: false))
        }
        let open: Bool
        switch recording.conclusion {
        case let .finished(atTime):
            let offset = atTime ?? recording.events.last?.offset ?? .zero
            try steps.append(Step(deadline: time.logicalTime(after: offset, from: anchor),
                                  delivery: .finished, terminal: true))
            open = false
        case let .failed(moment):
            try steps.append(Step(deadline: time.logicalTime(after: moment.offset, from: anchor),
                                  delivery: .failed(moment.value), terminal: true))
            open = false
        case .openAtRecordingHorizon:
            open = true
        }
        let subscription = Self(hasSteps: !steps.isEmpty, open: open)
        if !steps.isEmpty {
            let activity = Activity(claim: claim, scheduling: scheduling, steps: steps, deliver: deliver)
            do {
                try subscription.schedule(0, activity: activity, initial: true)
            } catch {
                subscription.cancel()
                throw error
            }
        }
        return subscription
    }

    /// Stops future delivery. The current in-flight callback may finish.
    @discardableResult
    public func cancel() -> Bool {
        let result = state.withLock { state -> (Bool, ScheduledItemHandle?) in
            switch state.phase {
            case .completed, .canceled: return (false, nil)
            case .registering, .pending, .delivering, .open:
                state.phase = .canceled
                let pending = state.pending
                state.pending = nil
                return (true, pending)
            }
        }
        result.1?.cancel()
        return result.0
    }

    private func schedule(_ index: Int, activity: Activity, initial: Bool) throws(SchedulingFailure) {
        guard state.withLock({ state in
            if case .registering(index) = state.phase {
                return true
            }
            return false
        }) else { return }
        let step = activity.steps[index]
        let handle: ScheduledItemHandle? = if initial {
            try activity.scheduling.schedule(at: step.deadline, for: activity.claim.record.identity) {
                await self.perform(index, activity: activity)
            }
        } else {
            try activity.scheduling.scheduleIfOpen(at: step.deadline, for: activity.claim.record.identity) {
                await self.perform(index, activity: activity)
            }
        }
        guard let handle else {
            cancel()
            return
        }
        let shouldCancel = state.withLock { state in
            if case .registering(index) = state.phase {
                state.phase = .pending(index)
                state.pending = handle
                return false
            }
            return true
        }
        if shouldCancel {
            handle.cancel()
        }
    }

    private func perform(_ index: Int, activity: Activity) async {
        let accepted = state.withLock { state -> Bool in
            switch state.phase {
            case .registering(index), .pending(index):
                state.phase = .delivering(index)
                state.pending = nil
                return true
            default: return false
            }
        }
        guard accepted else { return }
        let step = activity.steps[index]
        await activity.deliver(step.delivery)
        if step.terminal {
            activity.claim.complete()
        } else {
            activity.claim.advance(to: UInt64(index + 1))
        }
        let next = state.withLock { state -> Int? in
            guard case .delivering(index) = state.phase else { return nil }
            if index + 1 < activity.steps.count {
                state.phase = .registering(index + 1)
                return index + 1
            }
            state.phase = activity.claim.record.value.isOpenAtRecordingHorizon ? .open : .completed
            return nil
        }
        if let next {
            do {
                try schedule(next, activity: activity, initial: false)
            } catch {
                cancel()
            }
        }
    }
}
