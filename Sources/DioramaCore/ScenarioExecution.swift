import Synchronization

/// One independently owned, explicitly finalized in-memory sequential run.
///
/// Startup publishes no execution until every system activates. Finish closes
/// leases, cleans adapters in reverse order, and retains one immutable result.
/// Neither cleanup nor diagnostic notification runs under the execution lock.
/// Correct cleanup requires awaiting ``finish()``; deinitialization is not a
/// lifecycle substitute. Returned dependencies must honor their lease closure.
public final class ScenarioExecution: Sendable {
    private struct ResourceContents: Sendable {
        var systems: [AnyActivatedSystem] = []
        var leases: [any AnySequentialLease] = []
    }

    private struct StartupRollback: Error {
        let cleanup: [AttachmentCleanup]
    }

    private final class Resources: Sendable {
        private let contents: Mutex<ResourceContents>
        private let usage: ExecutionUsage

        init(systems: [AnyActivatedSystem], leases: [any AnySequentialLease], usage: ExecutionUsage) {
            contents = Mutex(ResourceContents(systems: systems, leases: leases))
            self.usage = usage
        }

        func dependency<Dependency: Sendable>(for key: DependencyKey<Dependency>) -> Dependency? {
            contents.withLock { contents in
                contents.systems.first(where: { $0.attachmentID == key.attachmentID })?.dependency as? Dependency
            }
        }

        func finish(reporter: DiagnosticReporter) -> ScenarioFinalizationResult {
            let final = release(reporter: reporter)
            return ScenarioFinalizationResult(report: reporter.freeze(), cleanup: final.cleanup, usage: final.usage)
        }

        private func release(reporter: DiagnosticReporter) -> (cleanup: [AttachmentCleanup], usage: [AttachmentUsage]) {
            let detached = contents.withLock { contents in
                let detached = contents
                contents = ResourceContents()
                return detached
            }
            let tracks = detached.leases.map { $0.close() }
            // This scope drops dependencies and cleanup captures before freeze.
            // Their destruction, like callbacks, occurs outside all locks.
            return (ScenarioExecution.cleanUp(detached.systems, reporter: reporter), usage.snapshot(tracks))
        }
    }

    private enum State: Sendable {
        case running(Resources)
        case finishing(Task<ScenarioFinalizationResult, Never>)
        case finished(ScenarioFinalizationResult)
    }

    /// Lightweight diagnostic context, independently retainable after finish.
    public let reporter: DiagnosticReporter

    private let state: Mutex<State>
    private let admission: ExecutionAdmission

    private init(systems: [AnyActivatedSystem], leases: [any AnySequentialLease],
                 reporter: DiagnosticReporter, admission: ExecutionAdmission, usage: ExecutionUsage)
    {
        self.reporter = reporter
        self.admission = admission
        state = Mutex(.running(Resources(systems: systems, leases: leases, usage: usage)))
    }

    /// Prepares and activates a fresh execution from immutable configuration.
    ///
    /// Registration list order does not affect activation order. Every system
    /// prepares before any activates. Failure closes all created leases and
    /// unwinds successful activations in reverse order, continuing on cleanup
    /// failure. Arbitrary thrown errors are neither retained nor rendered.
    ///
    /// - Parameters:
    ///   - definition: Ordered attachment declarations and prepared stable data.
    ///   - systems: Exactly one registration for each declared attachment.
    ///   - sink: Optional safe diagnostic notification for this run.
    /// - Returns: A fully activated, independent execution.
    /// - Throws: A structured startup failure including rollback outcomes.
    public static func start(
        definition: ScenarioDefinition,
        systems: [AnyScenarioSystem],
        sink: DiagnosticSink? = nil) throws(ScenarioStartupFailure) -> ScenarioExecution
    {
        let reporter = DiagnosticReporter(definition: definition, sink: sink)
        let admission = ExecutionAdmission()
        guard validRegistrations(systems, definition: definition) else {
            reporter.record(Diagnostic(issue: .lifecycle(.invalidRegistration)))
            throw ScenarioStartupFailure(report: reporter.freeze())
        }
        ExecutionUsage(definition: definition).diagnoseUnattached(reporter: reporter)
        do {
            return try activate(definition: definition, systems: systems, reporter: reporter, admission: admission)
        } catch {
            // Prepared systems and activation resources have left their scope;
            // release-time facts therefore precede this immutable boundary too.
            throw ScenarioStartupFailure(report: reporter.freeze(), cleanup: error.cleanup)
        }
    }

    private static func activate(
        definition: ScenarioDefinition, systems: [AnyScenarioSystem], reporter: DiagnosticReporter,
        admission: ExecutionAdmission) throws(StartupRollback) -> ScenarioExecution
    {
        var prepared: [AnyPreparedSystem] = []
        var leases: [any AnySequentialLease] = []
        var activated: [AnyActivatedSystem] = []
        for attachment in definition.attachments {
            // Exact one-to-one registration was validated before any callbacks.
            guard let system = systems.first(where: { $0.attachmentID == attachment.id }) else {
                preconditionFailure("Validated system registration is missing")
            }
            let context = SystemPreparationContext(
                attachment: attachment,
                mode: attachment.modeOverride ?? definition.defaultMode,
                reporter: reporter, admission: admission)
            do {
                let preparedSystem = try system.prepare(context)
                let completion = context.end()
                leases += completion.leases
                guard completion.missing.isEmpty else {
                    for id in completion.missing {
                        reporter.record(Diagnostic(issue: .lifecycle(.unpreparedTrack), context: .track(id)))
                    }
                    throw ScenarioLifecycleIssue.preparationFailed
                }
                prepared.append(preparedSystem)
            } catch {
                leases += context.end().leases
                reporter.record(Diagnostic(issue: .lifecycle(.preparationFailed), context: .attachment(attachment.id)))
                admission.close()
                throw rollback(activated, leases: leases, reporter: reporter)
            }
        }

        for (attachment, preparedSystem) in zip(definition.attachments, prepared) {
            do {
                try activated.append(preparedSystem.activate())
            } catch {
                reporter.record(Diagnostic(issue: .lifecycle(.activationFailed), context: .attachment(attachment.id)))
                admission.close()
                throw rollback(activated, leases: leases, reporter: reporter)
            }
        }
        return ScenarioExecution(systems: activated, leases: leases, reporter: reporter, admission: admission,
                                 usage: ExecutionUsage(definition: definition))
    }

    /// Retrieves an activated dependency while the execution remains running.
    ///
    /// Retaining a returned handle does not extend its lease lifetime. A lookup
    /// racing finish may return a handle that has already closed by first use.
    ///
    /// - Parameter key: The configured system's typed dependency key.
    /// - Returns: The same activated dependency for repeated lookups in this run.
    /// - Throws: Safe, already-reported closed, missing, or incompatible lookup evidence.
    public func dependency<Dependency: Sendable>(
        _ key: DependencyKey<Dependency>) throws(DependencyAccessFailure) -> Dependency
    {
        let lookup: Result<Dependency, ScenarioLifecycleIssue> = state.withLock { state in
            guard case let .running(resources) = state else { return .failure(.executionClosed) }
            guard let dependency = resources.dependency(for: key)
            else { return .failure(.invalidDependencyRequest) }
            return .success(dependency)
        }
        switch lookup {
        case let .success(dependency): return dependency
        case let .failure(issue):
            let diagnostic = Diagnostic(issue: .lifecycle(issue), context: .attachment(key.attachmentID))
            reporter.record(diagnostic)
            throw DependencyAccessFailure(diagnostic: diagnostic)
        }
    }

    /// Retrieves the dependency activated for a configured system.
    ///
    /// This is equivalent to looking up ``ScenarioSystem/dependencyKey``.
    /// The system contributes no execution state and may be reused across
    /// independent starts.
    ///
    /// - Parameter system: The typed system configuration used at startup.
    /// - Returns: The activated dependency for this execution.
    /// - Throws: Safe, already-reported closed, missing, or incompatible lookup evidence.
    public func dependency<Dependency: Sendable>(
        _ system: ScenarioSystem<Dependency>) throws(DependencyAccessFailure) -> Dependency
    {
        try dependency(system.dependencyKey)
    }

    /// Closes admission and awaits one execution-owned cleanup operation.
    ///
    /// Repeated callers receive the same immutable result. Cancellation of a
    /// caller does not cancel or abandon cleanup; this basic boundary still
    /// awaits completion. The task is owned by the execution, is not detached,
    /// and captures resources rather than the execution itself. Cleanup must
    /// not wait for a recursive call to this execution's finish operation.
    ///
    /// - Returns: Immutable usage, diagnostics, health, and ordered cleanup outcomes.
    public func finish() async -> ScenarioFinalizationResult {
        let selected = state.withLock { state in
            switch state {
            case let .running(resources):
                admission.close()
                let reporter = reporter
                let task = Task { resources.finish(reporter: reporter) }
                state = .finishing(task)
            case .finishing, .finished: break
            }
            return state
        }
        guard case let .finishing(operation) = selected else {
            if case let .finished(result) = selected {
                return result
            }
            preconditionFailure("Finish must close execution admission")
        }
        let result = await operation.value
        state.withLock { $0 = .finished(result) }
        return result
    }

    private static func validRegistrations(_ systems: [AnyScenarioSystem], definition: ScenarioDefinition) -> Bool {
        let ids = systems.map(\.attachmentID)
        return Set(ids).count == ids.count && Set(ids) == Set(definition.attachments.map(\.id))
    }

    private static func rollback(
        _ systems: [AnyActivatedSystem], leases: [any AnySequentialLease],
        reporter: DiagnosticReporter) -> StartupRollback
    {
        for lease in leases {
            lease.close()
        }
        let cleanup = cleanUp(systems, reporter: reporter)
        return StartupRollback(cleanup: cleanup)
    }

    private static func cleanUp(
        _ systems: [AnyActivatedSystem], reporter: DiagnosticReporter) -> [AttachmentCleanup]
    {
        var outcomes: [AttachmentCleanup] = []
        for system in systems.reversed() {
            let disposition: AttachmentCleanup.Disposition
            do {
                try system.deactivate()
                disposition = .completed
            } catch {
                reporter.record(Diagnostic(
                    issue: .lifecycle(.cleanupFailed), context: .attachment(system.attachmentID)))
                disposition = .failed
            }
            outcomes.append(AttachmentCleanup(attachmentID: system.attachmentID, disposition: disposition))
        }
        return outcomes.reversed()
    }
}
