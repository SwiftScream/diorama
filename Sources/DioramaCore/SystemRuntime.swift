import Synchronization

/// A detached projection of managed state, updated before every operation
/// unlocks, including throwing operations. Closure freezes the last value.
/// Projections must return stable values, never aliases to active resources.
public final class SystemSnapshot<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) {
        storage = Mutex(value)
    }

    /// The latest committed value, independently retainable after finish.
    public var value: Value {
        storage.withLock { $0 }
    }

    func update(_ value: Value) {
        storage.withLock { $0 = value }
    }
}

/// Core-owned record or replay state for one attachment and execution.
///
/// Protected closures, source calls, and projections are synchronous and must
/// not reenter, invoke arbitrary callbacks, schedule tasks, wait for finish, or
/// expose active-resource aliases. Use scoped operations for Core effects.
/// Deliver native callbacks and register/cancel scheduled work outside state
/// protection. Passthrough never creates a runtime.
public final class SystemRuntime<State: Sendable>: Sendable {
    private struct Storage: Sendable {
        var active: State?
        var projections: [@Sendable (State) -> Void] = []
    }

    private let storage: Mutex<Storage>
    private let operations: ManagedOperations
    /// Independently retainable safe diagnostic ledger. Notifications produced
    /// under state protection are buffered automatically by Core.
    public let reporter: DiagnosticReporter
    private let attachmentID: AttachmentID

    /// Logical-time capture and checked arithmetic shared by this execution.
    public let time: ExecutionTime
    /// The execution clock, usable outside protected operations.
    public let clock: ScenarioClock
    /// Ordered handoffs; register and cancel outside protected operations.
    public let scheduling: SchedulingLease

    /// Whether managed operation admission is closed. This inspection does not
    /// itself diagnose; an attempted operation after closure does.
    public var isClosed: Bool {
        operations.isClosed
    }

    init(state: State, context: SystemPreparationContext) {
        storage = Mutex(Storage(active: state))
        operations = ManagedOperations(admission: context.admission)
        reporter = context.reporter
        attachmentID = context.attachmentID
        time = context.time
        clock = context.clock
        scheduling = context.scheduling
    }

    /// Admits and serializes a complete synchronous operation. Notifications
    /// run after state and snapshots commit, even when the operation throws.
    /// Finish joins admitted operations and their notification delivery.
    public func withActiveState<Result>(
        _ body: (inout State, inout SystemOperation<State>) throws -> Result) throws -> Result
    {
        guard operations.enter() else { throw closedFailure() }
        defer { operations.leave() }
        var operation = SystemOperation(runtime: self, reporter: reporter)
        return try protected { state in try body(&state, &operation) }
    }

    /// Registers a pure snapshot projection during dependency construction.
    /// The runtime releases its projection at closure; snapshots retain only
    /// the projected value. Register before exposing the dependency.
    public func snapshot<Value: Sendable>(
        _ project: @escaping @Sendable (State) -> Value) -> SystemSnapshot<Value>
    {
        storage.withLock { storage in
            guard let state = storage.active else {
                preconditionFailure("Register snapshots during dependency construction")
            }
            let snapshot = SystemSnapshot(project(state))
            storage.projections.append { snapshot.update(project($0)) }
            return snapshot
        }
    }

    func join() async {
        await operations.join()
    }

    func close(cleanup: (State) throws -> Void) throws {
        operations.close()
        let detached = storage.withLock { storage in
            let detached = storage
            storage = Storage()
            return detached
        }
        if let state = detached.active {
            try cleanup(state)
        }
        withExtendedLifetime(detached) {}
    }

    /// Only execution-owned incremental freeze can enter after admission closes.
    /// Leases freeze after the operation join and before active state detaches.
    func freeze<Result>(_ body: (inout State) -> Result) -> Result? {
        try? protected(body)
    }

    private func protected<Result>(_ body: (inout State) throws -> Result) throws -> Result {
        let effects = ManagedEffects()
        defer { effects.deliver() }
        return try ManagedEffects.$current.withValue(effects) {
            try storage.withLock { storage in
                guard var state = storage.active else { throw closedFailure() }
                defer {
                    storage.active = state
                    for project in storage.projections {
                        project(state)
                    }
                }
                return try body(&state)
            }
        }
    }

    private func closedFailure() -> SequentialOperationFailure {
        let diagnostic = Diagnostic(issue: .lifecycle(.leaseClosed), context: .attachment(attachmentID))
        reporter.record(diagnostic)
        return SequentialOperationFailure(diagnostic: diagnostic)
    }
}
