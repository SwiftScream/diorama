/// A prepared system, private to one startup attempt.
///
/// Preparation must not install adapters or expose usable dependencies. The
/// activation closure runs only after every attachment and declared track is
/// prepared.
public struct PreparedSystem<Dependency: Sendable>: Sendable {
    let activate: @Sendable () throws -> ActivatedSystem<Dependency>

    /// Creates a prepared system for one fresh execution.
    ///
    /// - Parameter activate: Installs the sequential adapter and returns its
    ///   dependency and cleanup callback. If this callback throws, it must
    ///   unwind its own partial installation; only returned activations can
    ///   participate in execution-owned rollback. Do not publish dependencies
    ///   from the callback; retrieve them from the successfully started run.
    public init(activate: @escaping @Sendable () throws -> ActivatedSystem<Dependency>) {
        self.activate = activate
    }
}

/// An installed sequential adapter and its execution-owned cleanup obligation.
public struct ActivatedSystem<Dependency: Sendable>: Sendable {
    let dependency: Dependency
    let deactivate: @Sendable () throws -> Void

    /// Creates a successful activation.
    ///
    /// - Parameters:
    ///   - dependency: The consumer-facing handle. It should own leases, not
    ///     the execution or live resources that must be released at finish.
    ///   - deactivate: Synchronous sequential-adapter cleanup, called exactly
    ///     once by finish or startup rollback. Release Diorama-owned resources;
    ///     do not close or cancel consumer-owned sources. Native asynchronous
    ///     quiescence is not part of this sequential extension boundary.
    public init(dependency: Dependency, deactivate: @escaping @Sendable () throws -> Void) {
        self.dependency = dependency
        self.deactivate = deactivate
    }
}

/// One immutable attachment and its reusable typed runtime preparation.
///
/// A system is setup configuration, not execution state. It can start several
/// independent executions; each preparation call must create fresh per-run
/// state. Use ``AnyScenarioSystem`` to combine systems with heterogeneous
/// dependency types at startup.
public struct ScenarioSystem<Dependency: Sendable>: Sendable {
    /// The immutable stable content contributed to a programmatic definition.
    public let attachment: ScenarioAttachment

    /// The typed key used to retrieve this system's activated dependency.
    public let dependencyKey: DependencyKey<Dependency>

    let prepare: @Sendable (SystemPreparationContext) throws -> PreparedSystem<Dependency>

    /// Creates one reusable typed system.
    ///
    /// The attachment and dependency key always derive from the attachment's
    /// complete identity. Preparation runs independently for every execution
    /// startup. The context closes when this synchronous callback returns or
    /// throws; do not launch work that continues using it afterward.
    ///
    /// - Parameters:
    ///   - attachment: Immutable stable attachment content.
    ///   - prepare: Creates a fresh prepared system for each execution.
    public init(
        attachment: ScenarioAttachment,
        prepare: @escaping @Sendable (SystemPreparationContext) throws -> PreparedSystem<Dependency>)
    {
        self.attachment = attachment
        dependencyKey = DependencyKey(attachmentID: attachment.id)
        self.prepare = prepare
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

    let prepare: @Sendable (SystemPreparationContext) throws -> AnyPreparedSystem

    /// Erases a typed system for heterogeneous execution startup.
    ///
    /// - Parameter system: The typed reusable system to erase.
    public init(_ system: ScenarioSystem<some Sendable>) {
        let attachmentID = system.attachment.id
        let prepare = system.prepare
        self.attachmentID = attachmentID
        self.prepare = { context in
            let prepared = try prepare(context)
            return AnyPreparedSystem {
                let activation = try prepared.activate()
                return AnyActivatedSystem(
                    attachmentID: attachmentID,
                    dependency: activation.dependency,
                    deactivate: activation.deactivate)
            }
        }
    }
}

struct AnyPreparedSystem: Sendable {
    let activate: @Sendable () throws -> AnyActivatedSystem
}

struct AnyActivatedSystem: Sendable {
    let attachmentID: AttachmentID
    let dependency: any Sendable
    let deactivate: @Sendable () throws -> Void
}
