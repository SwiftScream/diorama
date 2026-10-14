import Synchronization

/// Core-owned state and services for one attachment in any execution mode.
/// State access never establishes isolation for native actors or shared references.
/// Passthrough has no prepared tracks; its live dependency keeps native behavior.
public final class SystemExecution<State: Sendable>: Sendable {
    private struct Storage: Sendable {
        var active: State?
    }

    private let storage: Mutex<Storage>
    private let operations: OperationTracker
    let attachmentID: AttachmentID

    /// Protected mutation and tracked access to individual state members.
    public var state: SystemStateAccess<State> {
        SystemStateAccess(execution: self)
    }

    /// Independently retainable diagnostic ledger, visible only after finalization.
    public let reporter: DiagnosticReporter
    /// Logical-time capture and checked arithmetic shared by this execution.
    public let time: ExecutionTime
    /// The execution clock, usable outside protected operations.
    public let clock: ScenarioClock
    /// Ordered handoffs; register and cancel outside protected operations.
    public let scheduling: SchedulingLease
    /// Whether ordinary state and tracked-value admission is closed.
    public var isClosed: Bool {
        operations.isClosed
    }

    init(state: State, context: SystemPreparationContext) {
        storage = Mutex(Storage(active: .some(state)))
        operations = OperationTracker(admission: context.admission)
        reporter = context.reporter
        attachmentID = context.attachmentID
        time = context.time
        clock = context.clock
        scheduling = context.scheduling
    }

    func withState<Result>(
        _ body: (inout State, inout SystemOperation<State>) throws -> Result) throws -> Result
    {
        _ = try enter(quiet: false)
        defer { leave() }
        return try mutate(body)
    }

    func mutate<Result>(
        _ body: (inout State, inout SystemOperation<State>) throws -> Result) throws -> Result
    {
        var operation = SystemOperation(execution: self, reporter: reporter)
        return try protected { state in try body(&state, &operation) }
    }

    func enter(quiet: Bool) throws -> Bool {
        try checkUnlocked()
        if quiet, !operations.isPublished {
            return false
        }
        guard operations.enter() else {
            if quiet {
                return false
            }
            throw failure(.leaseClosed)
        }
        return true
    }

    func checkUnlocked() throws {
        if PostUnlockActions.current != nil {
            throw failure(.trackedValueInsideState)
        }
    }

    func leave() {
        operations.leave()
    }

    func join() async {
        await operations.waitUntilIdle()
    }

    func closeAdmission() {
        operations.closeAdmission()
    }

    func detach() {
        operations.closeAdmission()
        let detached = storage.withLock { storage in
            let detached = storage
            storage = Storage()
            return detached
        }
        withExtendedLifetime(detached) {}
    }

    /// Only execution-owned incremental freeze enters after cleanup and before detach.
    func freeze<Result>(_ body: (inout State) -> Result) -> Result? {
        try? protected(body)
    }

    func protected<Result>(_ body: (inout State) throws -> Result) throws -> Result {
        let actions = PostUnlockActions()
        defer { actions.drain() }
        return try PostUnlockActions.$current.withValue(actions) {
            try storage.withLock { storage in
                guard var state = storage.active else { throw failure(.leaseClosed) }
                defer { storage.active = .some(state) }
                return try body(&state)
            }
        }
    }

    func failure(_ issue: ScenarioLifecycleIssue) -> SequentialOperationFailure {
        let diagnostic = Diagnostic(issue: .lifecycle(issue), context: .attachment(attachmentID))
        reporter.record(diagnostic)
        return SequentialOperationFailure(diagnostic: diagnostic)
    }
}
