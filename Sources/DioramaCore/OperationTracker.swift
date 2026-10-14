import Synchronization

/// Counts admitted operations and resumes waiting callers when the count reaches zero.
/// Closing admission prevents new operations from extending the wait. This tracker
/// does not serialize operations; its lock protects only admission, the count, and waiters.
final class OperationTracker: Sendable {
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

    var isPublished: Bool {
        admission.isPublished
    }

    /// Rejects new operations without interrupting or waiting for admitted operations.
    func closeAdmission() {
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

    /// Waits until no admitted operations remain. Does not close admission.
    func waitUntilIdle() async {
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
