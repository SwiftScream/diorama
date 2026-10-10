import Synchronization

/// Synchronous work and capture releases deferred until the enclosing managed state unlocks.
/// Actions run immediately when no protected state operation is active.
final class PostUnlockActions: Sendable {
    @TaskLocal static var current: PostUnlockActions?

    private let actions = Mutex<[@Sendable () -> Void]>([])

    /// Defers work until managed state unlocks, or runs it immediately outside an operation.
    static func perform(_ action: @escaping @Sendable () -> Void) {
        if let current {
            current.append(action)
        } else {
            action()
        }
    }

    private func append(_ action: @escaping @Sendable () -> Void) {
        actions.withLock { $0.append(action) }
    }

    /// Runs queued actions in insertion order. Call after leaving state protection.
    func drain() {
        var detached = actions.withLock { actions in
            let detached = actions
            actions = []
            return detached
        }
        detached.reverse()
        // Drop each callback's captures before running the next action.
        // Destruction is itself allowed to reenter the committed system state.
        while let action = detached.popLast() {
            action()
        }
    }
}
