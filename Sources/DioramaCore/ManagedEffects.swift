import Synchronization

/// Effects admitted by one synchronous state operation. Facts are retained at
/// their observation point; foreign code runs only after state is committed.
final class ManagedEffects: Sendable {
    @TaskLocal static var current: ManagedEffects?

    private let actions = Mutex<[@Sendable () -> Void]>([])

    func append(_ action: @escaping @Sendable () -> Void) {
        actions.withLock { $0.append(action) }
    }

    func deliver() {
        var detached = actions.withLock { actions in
            let detached = actions
            actions = []
            return detached
        }
        detached.reverse()
        // Drop each callback's captures before publishing the next effect.
        // Destruction is itself allowed to reenter the committed runtime.
        while let action = detached.popLast() {
            action()
        }
    }
}

/// The admission test and waiter installation share this lock. Once execution
/// admission closes, no new operation can extend the finalization join.
final class ManagedOperations: Sendable {
    private struct State: Sendable {
        var count = 0
        var closed = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    private let admission: ExecutionAdmission

    init(admission: ExecutionAdmission) {
        self.admission = admission
    }

    func enter() -> Bool {
        state.withLock { state in
            guard !state.closed, !admission.isClosed else { return false }
            state.count += 1
            return true
        }
    }

    var isClosed: Bool {
        admission.isClosed || state.withLock { $0.closed }
    }

    func close() {
        state.withLock { $0.closed = true }
    }

    func leave() {
        let waiters = state.withLock { state in
            state.count -= 1
            guard state.count == 0 else { return [CheckedContinuation<Void, Never>]() }
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func join() async {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state in
                guard state.count != 0 else { return true }
                state.waiters.append(continuation)
                return false
            }
            if done {
                continuation.resume()
            }
        }
    }
}
