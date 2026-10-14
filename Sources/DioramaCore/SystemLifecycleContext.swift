/// Result of awaited shutdown. Every result promises owned activity has stopped;
/// failure describes ancillary cleanup, never unfinished work.
public enum SystemCleanupResult: Equatable, Sendable {
    /// Shutdown completed successfully.
    case completed
    /// Shutdown completed with a safe, system-defined cleanup failure.
    case failed(DiagnosticLabel)
}

/// Privileged access valid only during one definition-level lifecycle hook.
/// No recording, scheduling, or operation effects are available through this context.
public struct SystemLifecycleContext<State: Sendable>: ~Copyable, Sendable {
    /// Protected state access. A retained view expires when this hook returns.
    public let state: SystemLifecycleStateAccess<State>
}

/// State access shared with the runtime but independent of consumer admission.
/// Select native references here, then use them outside protection on their actor.
/// Do not clear records needed by freeze or launch work without owning its shutdown.
public final class SystemLifecycleStateAccess<State: Sendable>: Sendable {
    private let execution: SystemExecution<State>
    private let operations = OperationTracker(admission: ExecutionAdmission())

    init(execution: SystemExecution<State>) {
        self.execution = execution
    }

    /// Mutates lifecycle state without Core effects. Throws after hook expiry.
    /// Native references may be copied; their ownership remains the author's duty.
    public func withLock<Result>(_ body: (inout State) throws -> Result) throws -> Result {
        try execution.checkUnlocked()
        guard operations.enter() else { throw execution.failure(.lifecycleContextClosed) }
        defer { operations.leave() }
        return try execution.protected(body)
    }

    func expire() async {
        operations.closeAdmission()
        await operations.waitUntilIdle()
    }
}

/// Retains typed state/dependency obligations across either startup milestone.
struct SystemLifecycle<State: Sendable, Dependency: Sendable>: Sendable {
    let execution: SystemExecution<State>
    let dependency: Dependency?
    let stop: @Sendable (borrowing SystemLifecycleContext<State>, Dependency?) async -> Void
    let cleanup: @Sendable (borrowing SystemLifecycleContext<State>, Dependency?) async -> SystemCleanupResult

    func begin() async {
        execution.closeAdmission()
        let access = SystemLifecycleStateAccess(execution: execution)
        await stop(SystemLifecycleContext(state: access), dependency)
        await access.expire()
    }

    func end() async throws {
        let access = SystemLifecycleStateAccess(execution: execution)
        let result = await cleanup(SystemLifecycleContext(state: access), dependency)
        await access.expire()
        if case let .failed(label) = result {
            execution.reporter.record(Diagnostic(issue: .system(label), context: .attachment(execution.attachmentID)))
            throw SystemCleanupFailure()
        }
    }
}

struct SystemCleanupFailure: Error {}
