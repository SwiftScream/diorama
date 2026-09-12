/// A prepared system's activation recipe, private to one startup attempt.
///
/// Preparation must not install adapters or expose usable dependencies. The
/// recipe runs only after every attachment and declared track is prepared.
public struct PreparedSystem<Dependency: Sendable>: Sendable {
    let activate: @Sendable () throws -> SystemActivation<Dependency>

    /// Creates an activation recipe for one fresh execution.
    ///
    /// - Parameter activate: Installs the sequential adapter and returns its
    ///   dependency and cleanup callback. If this callback throws, it must
    ///   unwind its own partial installation; only returned activations can
    ///   participate in execution-owned rollback. Do not publish dependencies
    ///   from the callback; retrieve them from the successfully started run.
    public init(activate: @escaping @Sendable () throws -> SystemActivation<Dependency>) {
        self.activate = activate
    }
}

/// An installed sequential adapter and its execution-owned cleanup obligation.
public struct SystemActivation<Dependency: Sendable>: Sendable {
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

/// A reusable registration for one named, sequential system attachment.
///
/// Registrations are supplied to startup separately from immutable track data.
/// Each preparation call must create fresh per-run state. A registration may
/// retain a consumer source factory; it must not share execution state between
/// starts. Heterogeneous dependency types can coexist in one registration list.
public struct ScenarioSystem: Sendable {
    /// The exact system type and key declared by the scenario definition.
    public let attachmentID: AttachmentID

    let prepare: @Sendable (SystemPreparationContext) throws -> PreparedActivation

    /// Registers a typed preparation callback for one attachment.
    ///
    /// - Parameters:
    ///   - attachmentID: The declaration to activate, regardless of list order.
    ///   - prepare: Requests every declared track through the context, selecting
    ///     its immutable preparation policy, then returns an activation recipe.
    ///     The context closes when this synchronous callback returns or throws.
    ///     Do not launch work that continues using it after the callback.
    public init(
        attachmentID: AttachmentID,
        prepare: @escaping @Sendable (SystemPreparationContext) throws -> PreparedSystem<some Sendable>)
    {
        self.attachmentID = attachmentID
        self.prepare = { context in
            let prepared = try prepare(context)
            return PreparedActivation {
                let activation = try prepared.activate()
                return ActivatedSystem(
                    attachmentID: attachmentID,
                    dependency: activation.dependency,
                    deactivate: activation.deactivate)
            }
        }
    }
}

struct PreparedActivation: Sendable {
    let activate: @Sendable () throws -> ActivatedSystem
}

struct ActivatedSystem: Sendable {
    let attachmentID: AttachmentID
    let dependency: any Sendable
    let deactivate: @Sendable () throws -> Void
}
