/// Reusable system configuration. Core validates all declarations before any
/// state or dependency factory runs. Each execution receives fresh mode state.
/// Native passthrough has only a dependency factory and ordinary native lifetime.
public protocol SystemDefinition: Sendable {
    /// Application-facing dependency; no Diorama protocol or base class required.
    associatedtype Dependency: Sendable
    /// Entire mutable state owned by Core while recording.
    associatedtype RecordState: Sendable
    /// Entire mutable state owned by Core while replaying.
    associatedtype ReplayState: Sendable

    /// Shared identity and optional persistence capability.
    var systemType: ScenarioSystemType { get }
    /// Typed declarations in deterministic layout order.
    var tracks: [AnySystemTrack] { get }

    /// Read-only validation of resolved content. Passthrough has no track access.
    func validate(in context: borrowing SystemValidationContext) throws
    /// Creates record state after every system has validated. A throwing state
    /// factory must unwind its own partial resource construction.
    func makeRecordState(in context: borrowing SystemStateContext) throws -> RecordState
    /// Creates replay state without contacting a live source. A throwing state
    /// factory must unwind its own partial resource construction.
    func makeReplayState(in context: borrowing SystemStateContext) throws -> ReplayState
    /// Creates the recording facade. Do not publish it before startup returns.
    func makeRecordDependency(using runtime: SystemRuntime<RecordState>) throws -> Dependency
    /// Creates the replay facade. Do not publish it before startup returns.
    func makeReplayDependency(using runtime: SystemRuntime<ReplayState>) throws -> Dependency
    /// Creates an ordinary live dependency with consumer-owned cleanup.
    func makePassthroughDependency() throws -> Dependency
    /// Cleans detached recording state, outside protection, exactly once.
    /// Also runs if dependency construction throws after state creation.
    func cleanUpRecordState(_ state: RecordState) throws
    /// Cleans detached replay state, outside protection, exactly once.
    func cleanUpReplayState(_ state: ReplayState) throws
}

public extension SystemDefinition {
    /// The default definition has no tracks.
    var tracks: [AnySystemTrack] {
        []
    }

    /// The default adds no validation beyond declared content policies.
    func validate(in _: borrowing SystemValidationContext) throws {}
    /// The default releases the detached state through ordinary Swift ownership.
    func cleanUpRecordState(_: RecordState) throws {}
    /// The default releases the detached state through ordinary Swift ownership.
    func cleanUpReplayState(_: ReplayState) throws {}
}

/// Read-only scoped access to the authoritative prepared baseline. This value
/// cannot escape validation. Stable content must not contain resource aliases.
public struct SystemValidationContext: ~Copyable {
    let registry: SystemTrackRegistry
    /// Exact keyed system being validated.
    public let attachmentID: AttachmentID
    /// Resolved attachment mode; passthrough permits setup checks only.
    public let mode: ScenarioMode

    /// Retrieves already-prepared content without capture transforms or claims.
    public func track<Value: Sendable, Header: Sendable>(
        _ declaration: SystemTrack<Value, Header>) throws -> SequentialTrack<Value, Header>
    {
        try registry.entry(for: declaration).content
    }

    /// Validates complete content and reports safe track-context failure.
    public func validate<Value: Sendable, Header: Sendable>(
        _ declaration: SystemTrack<Value, Header>,
        using validate: (SequentialTrack<Value, Header>) throws -> Void) throws
    {
        let content = try track(declaration)
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
public struct SystemStateContext: ~Copyable {
    let registry: SystemTrackRegistry
    /// Exact keyed system being activated.
    public let attachmentID: AttachmentID
    /// Logical time becomes available after all systems activate.
    public let time: ExecutionTime
    /// Shared application clock, independently usable outside state protection.
    public let clock: ScenarioClock
    /// Ordered handoffs, registered outside state protection after startup.
    public let scheduling: SchedulingLease

    /// Reads the resolved stable header and values without claims or transforms.
    public func track<Value: Sendable, Header: Sendable>(
        _ declaration: SystemTrack<Value, Header>) throws -> SequentialTrack<Value, Header>
    {
        try registry.entry(for: declaration).content
    }

    /// Returns this declaration's fresh lease for the current execution.
    public func lease<Value: Sendable, Header: Sendable>(
        for declaration: SystemTrack<Value, Header>) throws -> SequentialTrackLease<Value, Header>
    {
        try registry.entry(for: declaration).lease
    }
}

public extension ScenarioSystem {
    /// Derives layout, validates resolved content, and installs fresh managed
    /// state using one typed public system definition. Duplicate keys fail setup.
    init<Definition: SystemDefinition>(
        named name: String, definition: Definition, allowsUnclaimedReplayRecords: Bool = false) throws
        where Definition.Dependency == Dependency
    {
        let id = AttachmentID(systemTypeID: definition.systemType.id, key: AttachmentKey(rawValue: name))
        let tracks = definition.tracks
        var attachment = ScenarioAttachment(id: id)
        for track in tracks {
            attachment = try track.add(attachment)
        }
        try self.init(type: definition.systemType, attachment: attachment,
                      allowsUnclaimedReplayRecords: allowsUnclaimedReplayRecords)
        { context in
            var entries: [ObjectIdentifier: any Sendable] = [:]
            if context.mode != .passthrough {
                for track in tracks {
                    entries[track.identity] = try track.prepare(context)
                }
            }
            let registry = SystemTrackRegistry(entries: entries, attachmentID: id, reporter: context.reporter)
            try definition.validate(in: SystemValidationContext(
                registry: registry, attachmentID: id, mode: context.mode))
            return PreparedSystem {
                let stateContext = SystemStateContext(
                    registry: registry, attachmentID: id,
                    time: context.time, clock: context.clock, scheduling: context.scheduling)
                switch context.mode {
                case .passthrough:
                    return try ActivatedSystem(dependency: definition.makePassthroughDependency(), deactivate: {})
                case .record:
                    return try activateManaged(state: definition.makeRecordState(in: stateContext), context: context,
                                               dependency: definition.makeRecordDependency,
                                               cleanup: definition.cleanUpRecordState)
                case .replay:
                    return try activateManaged(state: definition.makeReplayState(in: stateContext), context: context,
                                               dependency: definition.makeReplayDependency,
                                               cleanup: definition.cleanUpReplayState)
                }
            }
        }
    }
}

private func activateManaged<State: Sendable, Dependency: Sendable>(
    state: State, context: SystemPreparationContext,
    dependency: (SystemRuntime<State>) throws -> Dependency,
    cleanup: @escaping @Sendable (State) throws -> Void) throws -> ActivatedSystem<Dependency>
{
    let runtime = SystemRuntime(state: state, context: context)
    do {
        return try ActivatedSystem(dependency: dependency(runtime),
                                   deactivate: { try runtime.close(cleanup: cleanup) },
                                   quiesce: { await runtime.join() })
    } catch {
        do { try runtime.close(cleanup: cleanup) } catch {
            context.reporter.record(Diagnostic(issue: .lifecycle(.cleanupFailed),
                                               context: .attachment(context.attachmentID)))
        }
        throw error
    }
}
