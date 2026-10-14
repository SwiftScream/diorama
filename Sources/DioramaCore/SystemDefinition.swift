/// Reusable system configuration. Core validates all declarations before any
/// state or dependency factory runs. Each execution receives fresh mode state.
/// All modes have state/dependency factories and definition-owned shutdown hooks.
public protocol SystemDefinition: Sendable {
    /// Application-facing dependency; no Diorama protocol or base class required.
    associatedtype Dependency: Sendable
    /// Entire mutable state owned by Core while recording.
    associatedtype RecordState: Sendable
    /// Entire mutable state owned by Core while replaying.
    associatedtype ReplayState: Sendable
    /// Ordinary live state; use Void when the dependency needs no managed state.
    associatedtype PassthroughState: Sendable = Void

    /// Shared identity and optional persistence capability.
    var systemType: ScenarioSystemType { get }
    /// Typed track definitions in deterministic layout order.
    var tracks: [AnyTrackDefinition] { get }

    /// Read-only validation of resolved content. Passthrough has no track access.
    func validate(in context: borrowing SystemValidationContext) throws
    /// Creates record state after every system has validated. A throwing state
    /// factory must unwind its own partial resource construction.
    func makeRecordState(in context: borrowing SystemStateContext) async throws -> RecordState
    /// Creates replay state without contacting a live source. A throwing state
    /// factory must unwind its own partial resource construction.
    func makeReplayState(in context: borrowing SystemStateContext) async throws -> ReplayState
    /// Creates live state without recording or replay content access.
    func makePassthroughState(in context: borrowing SystemStateContext) async throws -> PassthroughState
    /// Creates the recording facade. Do not publish it before startup returns.
    func makeRecordDependency(using execution: SystemExecution<RecordState>) async throws -> Dependency
    /// Creates the replay facade. Do not publish it before startup returns.
    func makeReplayDependency(using execution: SystemExecution<ReplayState>) async throws -> Dependency
    /// Creates the ordinary live dependency. Hooks determine its shutdown policy.
    func makePassthroughDependency(using execution: SystemExecution<PassthroughState>) async throws -> Dependency

    /// Signals recording stop without waiting for admitted operations to drain.
    func requestStopRecord(using lifecycle: borrowing SystemLifecycleContext<RecordState>,
                           dependency: Dependency?) async
    /// Joins recording-owned activity; preserve state needed by record freeze.
    func cleanUpRecord(using lifecycle: borrowing SystemLifecycleContext<RecordState>, dependency: Dependency?) async
        -> SystemCleanupResult
    /// Signals replay stop without waiting for admitted operations to drain.
    func requestStopReplay(using lifecycle: borrowing SystemLifecycleContext<ReplayState>,
                           dependency: Dependency?) async
    /// Joins replay-owned activity before Core freezes and releases state.
    func cleanUpReplay(using lifecycle: borrowing SystemLifecycleContext<ReplayState>, dependency: Dependency?) async
        -> SystemCleanupResult
    /// Signals live stop, including rollback. Injected dependencies may need no action.
    func requestStopPassthrough(
        using lifecycle: borrowing SystemLifecycleContext<PassthroughState>, dependency: Dependency?) async
    /// Joins owned live activity. Hooks must tolerate consumer-initiated shutdown.
    func cleanUpPassthrough(
        using lifecycle: borrowing SystemLifecycleContext<PassthroughState>, dependency: Dependency?) async
        -> SystemCleanupResult
}

public extension SystemDefinition {
    /// The default definition has no tracks.
    var tracks: [AnyTrackDefinition] {
        []
    }

    /// The default adds no validation beyond declared content policies.
    func validate(in _: borrowing SystemValidationContext) throws {}

    /// The default stop hook has no work to signal.
    func requestStopRecord(using _: borrowing SystemLifecycleContext<RecordState>, dependency _: Dependency?) {}
    /// The default cleanup has no owned activity to join.
    func cleanUpRecord(using _: borrowing SystemLifecycleContext<RecordState>, dependency _: Dependency?)
        -> SystemCleanupResult
    {
        .completed
    }

    /// The default stop hook has no work to signal.
    func requestStopReplay(using _: borrowing SystemLifecycleContext<ReplayState>, dependency _: Dependency?) {}
    /// The default cleanup has no owned activity to join.
    func cleanUpReplay(using _: borrowing SystemLifecycleContext<ReplayState>, dependency _: Dependency?)
        -> SystemCleanupResult
    {
        .completed
    }

    /// The default preserves an injected dependency's ordinary live lifetime.
    func requestStopPassthrough(using _: borrowing SystemLifecycleContext<PassthroughState>,
                                dependency _: Dependency?) {}
    /// The default has no owned live activity to join.
    func cleanUpPassthrough(using _: borrowing SystemLifecycleContext<PassthroughState>, dependency _: Dependency?)
        -> SystemCleanupResult
    {
        .completed
    }
}

public extension SystemDefinition where PassthroughState == Void {
    /// Constructs empty live state when only the dependency needs construction.
    func makePassthroughState(in _: borrowing SystemStateContext) {}
}

/// Read-only scoped access to the authoritative prepared baseline. This value
/// cannot escape validation. Stable content must not contain resource aliases.
public struct SystemValidationContext: ~Copyable {
    let registry: PreparedTrackRegistry
    /// Exact keyed system being validated.
    public let attachmentID: AttachmentID
    /// Resolved attachment mode; passthrough permits setup checks only.
    public let mode: ScenarioMode

    /// Retrieves already-prepared content by key and value/header types, without
    /// capture transforms or claims. Uses the registered definition's policies.
    public func track<Value: Sendable, Header: Sendable>(
        _ definition: TrackDefinition<Value, Header>) throws -> SequentialTrack<Value, Header>
    {
        try registry.entry(for: definition).content
    }

    /// Validates complete content and reports safe track-context failure.
    public func validate<Value: Sendable, Header: Sendable>(
        _ definition: TrackDefinition<Value, Header>,
        using validate: (SequentialTrack<Value, Header>) throws -> Void) throws
    {
        let content = try track(definition)
        do { try validate(content) } catch {
            let diagnostic = Diagnostic(issue: .preparationFailed(.validation), context: .track(content.id))
            registry.reporter.record(diagnostic)
            throw PreparationFailure(diagnostic: diagnostic)
        }
    }
}

/// Scoped activation services. Track lookup returns the same prepared lease on
/// every call, without repeating policies or consuming records. Do not expose
/// active-resource aliases from subsequently protected state operations.
public struct SystemStateContext: ~Copyable, Sendable {
    let registry: PreparedTrackRegistry
    /// Exact keyed system being activated.
    public let attachmentID: AttachmentID
    /// Logical time becomes available after all systems activate.
    public let time: ExecutionTime
    /// Shared application clock, independently usable outside state protection.
    public let clock: ScenarioClock
    /// Ordered handoffs, registered outside state protection after startup.
    public let scheduling: SchedulingLease

    /// Reads the resolved stable header and values by key and value/header types,
    /// without claims or transforms. Uses the registered definition's policies.
    public func track<Value: Sendable, Header: Sendable>(
        _ definition: TrackDefinition<Value, Header>) throws -> SequentialTrack<Value, Header>
    {
        try registry.entry(for: definition).content
    }

    /// Returns the current execution's prepared lease by key and value/header
    /// types. Initial content and policies come from the registered definition.
    public func lease<Value: Sendable, Header: Sendable>(
        for definition: TrackDefinition<Value, Header>) throws -> SequentialTrackLease<Value, Header>
    {
        try registry.entry(for: definition).lease
    }
}
