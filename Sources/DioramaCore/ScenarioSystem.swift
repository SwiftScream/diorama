/// A prepared system, private to one startup attempt.
///
/// Preparation must not install adapters or expose usable dependencies. The
/// activation closure runs only after every attachment and declared track is
/// prepared.
struct PreparedSystem<Dependency: Sendable>: Sendable {
    let activate: @Sendable () async throws -> ActivatedSystem<Dependency>

    /// Creates a prepared system for one fresh execution.
    ///
    /// - Parameter activate: Installs the sequential adapter and returns its
    ///   dependency and cleanup callback. If this callback throws, it must
    ///   unwind its own partial installation; only returned activations can
    ///   participate in execution-owned rollback. Do not publish dependencies
    ///   from the callback; retrieve them from the successfully started run.
    init(activate: @escaping @Sendable () async throws -> ActivatedSystem<Dependency>) {
        self.activate = activate
    }
}

/// An installed dependency and its all-mode cleanup obligation.
struct ActivatedSystem<Dependency: Sendable>: Sendable {
    let dependency: Dependency
    let deactivate: @Sendable () async throws -> Void
    var quiesce: @Sendable () async -> Void = {}
    var beginFinalization: @Sendable () async -> Void = {}
    var release: @Sendable () -> Void = {}

    /// Creates a successful activation.
    ///
    /// - Parameters:
    ///   - dependency: The consumer-facing handle. Record/replay handles own
    ///     leases; passthrough returns the ordinary native dependency directly.
    ///   - deactivate: Awaited cleanup after stop requests and scope drainage.
    ///     Called once by finish or rollback in every mode. Hooks define which
    ///     work is owned, including any independent consumer forwarding lifetime.
    init(dependency: Dependency, deactivate: @escaping @Sendable () async throws -> Void) {
        self.dependency = dependency
        self.deactivate = deactivate
    }

    init(dependency: Dependency, deactivate: @escaping @Sendable () async throws -> Void,
         quiesce: @escaping @Sendable () async -> Void)
    {
        self.dependency = dependency
        self.deactivate = deactivate
        self.quiesce = quiesce
    }
}

/// One immutable attachment and its reusable typed runtime preparation.
///
/// A system is setup configuration, not execution state. It can start several
/// independent executions; each preparation call must create fresh per-run
/// state. Use ``AnyScenarioSystem`` to combine systems with heterogeneous
/// dependency types at startup.
public struct ScenarioSystem<Dependency: Sendable>: Sendable {
    /// Shared system-wide identity and optional capabilities.
    public let type: ScenarioSystemType

    /// The immutable stable content contributed to a programmatic definition.
    public let attachment: ScenarioAttachment

    /// The typed key used to retrieve this system's activated dependency.
    public let dependencyKey: DependencyKey<Dependency>

    /// This attachment's mode, or `nil` to inherit the scenario default.
    public private(set) var modeOverride: ScenarioMode?

    /// Whether unclaimed replay records are exempt from evaluation.
    public let allowsUnclaimedReplayRecords: Bool

    let prepare: @Sendable (SystemPreparationContext) throws -> PreparedSystem<Dependency>

    /// Derives layout, validates resolved content, and installs fresh managed
    /// state using one typed public system definition. Duplicate keys fail setup.
    public init<Definition: SystemDefinition>(
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
            var entries: [TrackKey: any PreparedTrackEntry] = [:]
            if context.mode != .passthrough {
                for track in tracks {
                    entries[track.key] = try track.prepare(context)
                }
            }
            let registry = PreparedTrackRegistry(entries: entries, attachmentID: id, reporter: context.reporter)
            try definition.validate(in: SystemValidationContext(
                registry: registry, attachmentID: id, mode: context.mode))
            return PreparedSystem {
                let stateContext = SystemStateContext(
                    registry: registry, attachmentID: id,
                    time: context.time, clock: context.clock, scheduling: context.scheduling)
                switch context.mode {
                case .passthrough:
                    let mode = definition.passthrough
                    return try await Self.activateManaged(
                        state: mode.makeState(stateContext), context: context,
                        dependency: mode.makeDependency,
                        stop: mode.requestStop, cleanup: mode.cleanUp)
                case .record:
                    let mode = definition.record
                    return try await Self.activateManaged(
                        state: mode.makeState(stateContext), context: context,
                        dependency: mode.makeDependency,
                        stop: mode.requestStop, cleanup: mode.cleanUp)
                case .replay:
                    let mode = definition.replay
                    return try await Self.activateManaged(
                        state: mode.makeState(stateContext), context: context,
                        dependency: mode.makeDependency,
                        stop: mode.requestStop, cleanup: mode.cleanUp)
                }
            }
        }
    }

    /// Creates one reusable typed system.
    ///
    /// The attachment and dependency key always derive from the attachment's
    /// complete identity. Preparation runs independently for every execution
    /// startup. The context closes when this synchronous callback returns or
    /// throws; do not launch work that continues using it afterward.
    ///
    /// - Parameters:
    ///   - type: Shared descriptor whose identity owns the attachment.
    ///   - attachment: Immutable stable attachment content.
    ///   - allowsUnclaimedReplayRecords: Whether unclaimed replay records are acceptable
    ///     for this attachment. A system factory chooses whether to expose this option.
    ///   - prepare: Creates a fresh prepared system for each execution.
    /// - Throws: An attachment identity belonging to another system type.
    init(
        type: ScenarioSystemType,
        attachment: ScenarioAttachment,
        allowsUnclaimedReplayRecords: Bool = false,
        prepare: @escaping @Sendable (SystemPreparationContext) throws -> PreparedSystem<Dependency>)
        throws(ScenarioDefinitionError)
    {
        guard type.id == attachment.id.systemTypeID else {
            throw .incompatibleAttachmentSystem(
                key: attachment.id.key, existing: type.id, proposed: attachment.id.systemTypeID)
        }
        self.type = type
        self.attachment = attachment
        dependencyKey = DependencyKey(attachmentID: attachment.id)
        modeOverride = nil
        self.allowsUnclaimedReplayRecords = allowsUnclaimedReplayRecords
        self.prepare = prepare
    }

    /// Returns a copy using a caller-selected mode for this attachment.
    /// Passing `nil` restores inheritance of the scenario default.
    public func withMode(_ mode: ScenarioMode?) -> Self {
        var copy = self
        copy.modeOverride = mode
        return copy
    }

    private static func activateManaged<State: Sendable>(
        state: State, context: SystemPreparationContext,
        dependency: (SystemExecution<State>) async throws -> Dependency,
        stop: @escaping @Sendable (borrowing SystemLifecycleContext<State>, Dependency?) async -> Void,
        cleanup: @escaping @Sendable (borrowing SystemLifecycleContext<State>, Dependency?)
        async -> SystemCleanupResult)
        async throws -> ActivatedSystem<Dependency>
    {
        // Adopt the returned state before any cancellation check or suspension.
        let execution = SystemExecution(state: state, context: context)
        let facade: Dependency
        do {
            try Task.checkCancellation()
            facade = try await dependency(execution)
        } catch {
            // Include this returned state in the common rollback. Never join it
            // before earlier attachments have received their stop requests.
            let lifecycle = SystemLifecycle(execution: execution, dependency: nil,
                                            stop: stop, cleanup: cleanup)
            throw SystemActivationFailure(
                canceled: error is CancellationError,
                partial: AnyActivatedSystem(
                    attachmentID: context.attachmentID, dependency: nil,
                    deactivate: { try await lifecycle.end() },
                    quiesce: { await execution.join() }, beginFinalization: { await lifecycle.begin() },
                    release: { execution.detach() }))
        }
        // Preserve the outer optional even when a successful Dependency is nil.
        let lifecycle = SystemLifecycle(execution: execution, dependency: .some(facade),
                                        stop: stop, cleanup: cleanup)
        var activation = ActivatedSystem(dependency: facade, deactivate: { try await lifecycle.end() },
                                         quiesce: { await execution.join() })
        activation.beginFinalization = { await lifecycle.begin() }
        activation.release = { execution.detach() }
        return activation
    }
}

/// A type-erased runtime registration for one scenario system.
///
/// Erasure retains the attachment identity and preparation behavior, but not
/// the typed system's immutable attachment content. Heterogeneous erased
/// systems can coexist in one startup list.
public struct AnyScenarioSystem: Sendable {
    /// The exact system type and key declared by the scenario definition.
    public let attachmentID: AttachmentID

    /// Per-attachment mode selected by the caller, if any.
    public let modeOverride: ScenarioMode?

    /// Whether this attachment waives unclaimed-replay-record evaluation.
    public let allowsUnclaimedReplayRecords: Bool

    let prepare: @Sendable (SystemPreparationContext) throws -> AnyPreparedSystem

    /// Erases a typed system for heterogeneous execution startup.
    ///
    /// - Parameter system: The typed reusable system to erase.
    public init(_ system: ScenarioSystem<some Sendable>) {
        let attachmentID = system.attachment.id
        let prepare = system.prepare
        self.attachmentID = attachmentID
        modeOverride = system.modeOverride
        allowsUnclaimedReplayRecords = system.allowsUnclaimedReplayRecords
        self.prepare = { context in
            let prepared = try prepare(context)
            return AnyPreparedSystem {
                let activation = try await prepared.activate()
                return AnyActivatedSystem(
                    attachmentID: attachmentID,
                    dependency: .some(activation.dependency),
                    deactivate: activation.deactivate,
                    quiesce: activation.quiesce, beginFinalization: activation.beginFinalization,
                    release: activation.release)
            }
        }
    }

    /// The attachment's selected mode after inheriting the scenario default.
    public func effectiveMode(defaultMode: ScenarioMode) -> ScenarioMode {
        modeOverride ?? defaultMode
    }
}

struct AnyPreparedSystem: Sendable {
    let activate: @Sendable () async throws -> AnyActivatedSystem
}

struct AnyActivatedSystem: Sendable {
    let attachmentID: AttachmentID
    let dependency: any Sendable?
    let deactivate: @Sendable () async throws -> Void
    var quiesce: @Sendable () async -> Void = {}
    var beginFinalization: @Sendable () async -> Void = {}
    var release: @Sendable () -> Void = {}
}

/// A returned state whose dependency factory settles unsuccessfully.
struct SystemActivationFailure: Error {
    let canceled: Bool
    let partial: AnyActivatedSystem
}
