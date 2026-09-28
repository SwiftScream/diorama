import Synchronization

/// Cancellation authority for one execution-owned scheduled item.
///
/// Copies share the same registration. Dropping a handle does not cancel work.
/// A terminal handle retains no callback captures or scheduler ownership.
public struct ScheduledItemHandle: Sendable {
    let registration: ScheduledRegistration

    /// Cancels pending delivery, returning true only for the call that wins.
    ///
    /// Claiming and cancellation are atomic alternatives. Once claimed, the
    /// delivery runs to completion, even during shutdown.
    /// Repeated cancellation and cancellation after claim return false.
    @discardableResult
    public func cancel() -> Bool {
        registration.engine?.cancel(registration) ?? false
    }
}

/// The engine serializes transitions; this small cell supports escaped tokens
/// without retaining the engine, its tasks, or any system callback captures.
final class ScheduledRegistration: Sendable {
    enum Phase: Sendable {
        case pending, claimed, completed, canceled
    }

    private struct State: Sendable {
        var phase: Phase = .pending
        weak var engine: DeadlineEngine?
    }

    private let state: Mutex<State>

    init(engine: DeadlineEngine) {
        state = Mutex(State(engine: engine))
    }

    var engine: DeadlineEngine? {
        state.withLock { $0.engine }
    }

    var phase: Phase {
        state.withLock { $0.phase }
    }

    /// Called only while holding the owning engine's lock.
    func transition(to phase: Phase) {
        state.withLock { state in
            state.phase = phase
            if phase == .completed || phase == .canceled {
                state.engine = nil
            }
        }
    }
}
