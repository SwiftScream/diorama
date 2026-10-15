/// Reusable construction and shutdown callbacks for one system mode.
///
/// Declare configuration here; create execution-owned resources inside the
/// factories. Core reads only the selected mode once per activation, after all
/// attachments validate. Factories own failed partial construction; Core adopts
/// successfully returned State and Dependency before checking cancellation.
/// Synchronous and actor-isolated functions can supply these async callbacks.
public struct SystemModeDefinition<State: Sendable, Dependency: Sendable>: Sendable {
    let makeState: @Sendable (borrowing SystemStateContext) async throws -> State
    let makeDependency: @Sendable (SystemExecution<State>) async throws -> Dependency
    let requestStop: @Sendable (borrowing SystemLifecycleContext<State>, Dependency?) async -> Void
    let cleanUp: @Sendable (borrowing SystemLifecycleContext<State>, Dependency?) async -> SystemCleanupResult

    /// Groups this mode's factories with optional shutdown callbacks.
    ///
    /// - Parameters:
    ///   - makeState: Creates fresh State after validation. Unwind anything this
    ///     factory fails to return, including activity requiring awaited cleanup.
    ///   - makeDependency: Creates the facade from adopted State. Do not publish
    ///     it before startup returns. Unwind its own failed partial construction.
    ///   - requestStop: Signals activity needed to unblock drainage; must not
    ///     wait for that drainage. Defaults to no work.
    ///   - cleanUp: Joins all owned activity after drainage, preserving State
    ///     needed by record freeze. Defaults to `.completed`.
    ///
    /// Lifecycle callbacks run on rollback and normal finish in every mode.
    /// Their optional Dependency distinguishes State-only ownership from a
    /// returned dependency, including `.some(nil)` for an optional dependency.
    /// Both cleanup outcomes promise quiescence. Passthrough callbacks determine
    /// native shutdown and must tolerate consumer-initiated shutdown.
    public init(
        makeState: @escaping @Sendable (borrowing SystemStateContext) async throws -> State,
        makeDependency: @escaping @Sendable (SystemExecution<State>) async throws -> Dependency,
        requestStop: @escaping @Sendable (borrowing SystemLifecycleContext<State>, Dependency?) async
            -> Void = { _, _ in },
        cleanUp: @escaping @Sendable (borrowing SystemLifecycleContext<State>, Dependency?) async
            -> SystemCleanupResult = { _, _ in .completed })
    {
        self.makeState = makeState
        self.makeDependency = makeDependency
        self.requestStop = requestStop
        self.cleanUp = cleanUp
    }
}

public extension SystemModeDefinition where State == Void {
    /// Supplies empty State while giving the dependency factory execution services.
    /// A dependency may still own activity requiring stop and awaited cleanup.
    init(
        makeDependency: @escaping @Sendable (SystemExecution<Void>) async throws -> Dependency,
        requestStop: @escaping @Sendable (borrowing SystemLifecycleContext<Void>, Dependency?) async
            -> Void = { _, _ in },
        cleanUp: @escaping @Sendable (borrowing SystemLifecycleContext<Void>, Dependency?) async
            -> SystemCleanupResult = { _, _ in .completed })
    {
        self.init(makeState: { _ in }, makeDependency: makeDependency,
                  requestStop: requestStop, cleanUp: cleanUp)
    }

    /// Supplies empty State for a dependency factory that needs no execution services.
    /// The factory runs for each execution; reading the declaration does not call it.
    /// Optional lifecycle callbacks can stop and join activity owned by Dependency.
    init(
        makeDependency: @escaping @Sendable () async throws -> Dependency,
        requestStop: @escaping @Sendable (borrowing SystemLifecycleContext<Void>, Dependency?) async
            -> Void = { _, _ in },
        cleanUp: @escaping @Sendable (borrowing SystemLifecycleContext<Void>, Dependency?) async
            -> SystemCleanupResult = { _, _ in .completed })
    {
        self.init(makeState: { _ in }, makeDependency: { _ in try await makeDependency() },
                  requestStop: requestStop, cleanUp: cleanUp)
    }
}
