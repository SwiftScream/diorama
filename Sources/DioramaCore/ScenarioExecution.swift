import Synchronization

private struct StartupServices {
    let reporter: DiagnosticReporter
    let admission: ExecutionAdmission
    let time: ExecutionTime
    let scheduler: DeadlineEngine

    func close() {
        admission.close()
        scheduler.stop()
        time.close()
    }
}

/// One independently owned, explicitly finalized in-memory scenario run.
///
/// Startup publishes no execution until every system activates. Finish closes
/// leases, joins scheduled handoffs and scoped deliveries, cleans
/// adapters in reverse order, and retains one immutable result.
/// Cleanup runs outside the execution lock; diagnostic retention invokes no callbacks.
/// Correct cleanup requires awaiting ``finish()``; deinitialization is not a
/// lifecycle substitute. Record/replay dependencies honor lease closure;
/// passthrough hooks determine ownership and the native shutdown policy.
public final class ScenarioExecution: Sendable {
    private struct ResourceContents: Sendable {
        var systems: [AnyActivatedSystem] = []
        var leases: [any AnySequentialLease] = []
        var definition: ScenarioDefinition?
    }

    private struct StartupRollback: Error {
        let cleanup: [AttachmentCleanup]
    }

    private struct FinalizedContents {
        let definition: ScenarioDefinition?
        let cleanup: [AttachmentCleanup]
        let usage: [AttachmentUsage]
    }

    private final class Resources: Sendable {
        private let contents: Mutex<ResourceContents>
        private let usage: ExecutionUsage
        let time: ExecutionTime
        private let scheduler: DeadlineEngine

        init(systems: [AnyActivatedSystem], leases: [any AnySequentialLease], usage: ExecutionUsage,
             definition: ScenarioDefinition, time: ExecutionTime, scheduler: DeadlineEngine)
        {
            contents = Mutex(ResourceContents(systems: systems, leases: leases, definition: definition))
            self.usage = usage
            self.time = time
            self.scheduler = scheduler
        }

        func dependency<Dependency: Sendable>(for key: DependencyKey<Dependency>) -> Dependency? {
            contents.withLock { contents in
                contents.systems.first(where: { $0.attachmentID == key.attachmentID })?.dependency as? Dependency
            }
        }

        func finish(reporter: DiagnosticReporter, horizonIssue: ExecutionTimeIssue?)
            async -> ScenarioFinalizationResult
        {
            if let horizonIssue {
                reporter.record(Diagnostic(issue: .logicalTime(horizonIssue), recordingImpact: .invalidatesCandidate))
            }
            let final = await finalizeResources(reporter: reporter)
            let report = reporter.freeze()
            return ScenarioFinalizationResult(definition: report.recordingHealth.isHealthy ? final.definition : nil,
                                              report: report, cleanup: final.cleanup, usage: final.usage)
        }

        private func finalizeResources(reporter: DiagnosticReporter) async -> FinalizedContents {
            let cleanup = await stopAndClean(reporter: reporter)
            return release(cleanup: cleanup, reporter: reporter)
        }

        private func stopAndClean(reporter: DiagnosticReporter) async -> [AttachmentCleanup] {
            scheduler.stop()
            let owners = contents.withLock { ($0.systems, $0.leases) }
            return await ScenarioExecution.stopAndClean(
                owners.0, leases: owners.1, scheduler: scheduler, reporter: reporter)
        }

        private func release(cleanup: [AttachmentCleanup], reporter: DiagnosticReporter) -> FinalizedContents {
            time.close()
            var detached = contents.withLock { contents in
                let detached = contents
                contents = ResourceContents()
                return detached
            }
            let tracks = detached.leases.map { $0.close() }
            for system in detached.systems {
                system.release()
            }
            // Drop dependencies and hook captures before candidate/report creation.
            // Their destruction may report or reenter and occurs outside all locks.
            detached.systems.removeAll()
            // Every capture and required runtime release contributes health before
            // the first merge. A failed merge also prevents subsequent merge work.
            let recordings = tracks.compactMap { track in
                reporter.isRecordingHealthy ? track.makeRecording() : nil
            }
            let definition = detached.definition?.replacingRecordings(recordings)
            return FinalizedContents(definition: definition,
                                     cleanup: cleanup,
                                     usage: usage.snapshot(tracks.map(\.usage)))
        }
    }

    private enum State: Sendable {
        case running(Resources)
        case finishing(Task<ScenarioFinalizationResult, Never>)
        case finished(ScenarioFinalizationResult)
    }

    /// Lightweight diagnostic context, independently retainable after finish.
    public let reporter: DiagnosticReporter

    /// Shared execution services, independent of system attachments and persistence.
    /// Retaining this value does not extend the execution or scheduler lifetime.
    public let context: ScenarioExecutionContext

    private let state: Mutex<State>

    private init(systems: [AnyActivatedSystem], leases: [any AnySequentialLease],
                 reporter: DiagnosticReporter, usage: ExecutionUsage,
                 definition: ScenarioDefinition, time: ExecutionTime, scheduler: DeadlineEngine)
    {
        self.reporter = reporter
        context = ScenarioExecutionContext(clock: ScenarioClock(time: time, scheduler: scheduler, reporter: reporter))
        state = Mutex(.running(Resources(systems: systems, leases: leases, usage: usage,
                                         definition: definition, time: time, scheduler: scheduler)))
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
    ///   - scenarioID: Diagnostic identity for this execution.
    ///   - defaultMode: Mode inherited by systems without an override.
    ///   - systems: Exactly one registration for each declared attachment.
    ///   - initialDiagnostics: Safe facts produced by pre-activation
    ///     orchestration, retained before any system callback.
    /// - Returns: A fully activated, independent execution.
    /// - Throws: A structured startup failure including rollback outcomes.
    public static func start(
        definition: ScenarioDefinition,
        scenarioID: ScenarioID,
        defaultMode: ScenarioMode,
        systems: [AnyScenarioSystem],
        initialDiagnostics: [Diagnostic] = []) async throws(ScenarioStartupFailure) -> ScenarioExecution
    {
        try await start(definition: definition, scenarioID: scenarioID, defaultMode: defaultMode,
                        systems: systems, initialDiagnostics: initialDiagnostics,
                        clock: .continuous())
    }

    static func start(
        definition: ScenarioDefinition,
        scenarioID: ScenarioID,
        defaultMode: ScenarioMode,
        systems: [AnyScenarioSystem],
        initialDiagnostics: [Diagnostic] = [],
        clock: ExecutionClock) async throws(ScenarioStartupFailure) -> ScenarioExecution
    {
        let reporter = DiagnosticReporter(scenarioID: scenarioID, definition: definition)
        for diagnostic in initialDiagnostics {
            reporter.record(diagnostic)
        }
        let admission = ExecutionAdmission()
        guard validRegistrations(systems, definition: definition) else {
            reporter.record(Diagnostic(issue: .lifecycle(.invalidRegistration)))
            throw ScenarioStartupFailure(report: reporter.freeze())
        }
        let time = ExecutionTime(clock: clock, admission: admission, reporter: reporter)
        let scheduler = DeadlineEngine(time: time, admission: admission, reporter: reporter)
        let services = StartupServices(reporter: reporter, admission: admission, time: time, scheduler: scheduler)
        do {
            return try await activate(
                definition: definition,
                defaultMode: defaultMode,
                systems: systems,
                services: services)
        } catch {
            // Prepared systems and activation resources have left their scope;
            // release-time facts therefore precede this immutable boundary too.
            throw ScenarioStartupFailure(report: reporter.freeze(), cleanup: error.cleanup)
        }
    }

    private static func activate(
        definition: ScenarioDefinition, defaultMode: ScenarioMode,
        systems: [AnyScenarioSystem], services: StartupServices) async throws(StartupRollback) -> ScenarioExecution
    {
        let reporter = services.reporter
        let admission = services.admission
        let time = services.time
        let scheduler = services.scheduler
        var prepared: [AnyPreparedSystem] = []
        var leases: [any AnySequentialLease] = []
        if Task.isCancelled {
            reporter.record(Diagnostic(issue: .lifecycle(.startupCanceled)))
            services.close()
            throw await rollback([], leases: leases, reporter: reporter)
        }
        for (order, attachment) in definition.attachments.enumerated() {
            // Exact one-to-one registration was validated before any callbacks.
            guard let system = systems.first(where: { $0.attachmentID == attachment.id }) else {
                preconditionFailure("Validated system registration is missing")
            }
            let context = SystemPreparationContext(
                attachment: attachment,
                mode: system.effectiveMode(defaultMode: defaultMode),
                reporter: reporter, admission: admission, time: time,
                clock: ScenarioClock(time: time, scheduler: scheduler, reporter: reporter),
                scheduling: SchedulingLease(engine: scheduler, attachment: attachment,
                                            order: order, reporter: reporter))
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
                services.close()
                throw await rollback([], leases: leases, reporter: reporter)
            }
        }

        let activated = try await activatePrepared(prepared, definition: definition, leases: leases, services: services)
        let usage = ExecutionUsage(definition: definition, defaultMode: defaultMode, systems: systems)
        let execution = ScenarioExecution(systems: activated, leases: leases, reporter: reporter,
                                          usage: usage, definition: definition, time: time, scheduler: scheduler)
        time.start()
        admission.publish()
        return execution
    }

    private static func activatePrepared(
        _ prepared: [AnyPreparedSystem], definition: ScenarioDefinition,
        leases: [any AnySequentialLease], services: StartupServices)
        async throws(StartupRollback) -> [AnyActivatedSystem]
    {
        let reporter = services.reporter
        var activated: [AnyActivatedSystem] = []
        for (attachment, preparedSystem) in zip(definition.attachments, prepared) {
            do {
                try Task.checkCancellation()
                try await activated.append(preparedSystem.activate())
                try Task.checkCancellation()
            } catch {
                let canceled: Bool
                if let failure = error as? SystemActivationFailure {
                    activated.append(failure.partial)
                    canceled = failure.canceled
                } else {
                    canceled = error is CancellationError
                }
                let issue: ScenarioLifecycleIssue = canceled ? .startupCanceled : .activationFailed
                reporter.record(Diagnostic(issue: .lifecycle(issue),
                                           context: .attachment(attachment.id)))
                services.close()
                throw await rollback(activated, leases: leases, reporter: reporter)
            }
        }
        if Task.isCancelled {
            reporter.record(Diagnostic(issue: .lifecycle(.startupCanceled)))
            services.close()
            throw await rollback(activated, leases: leases, reporter: reporter)
        }
        return activated
    }

    /// Retrieves an activated dependency while the execution remains running.
    ///
    /// Retaining a record/replay handle does not extend its lease lifetime. A
    /// lookup racing finish may return a managed handle already closed by first
    /// use. Passthrough hooks determine the native dependency's shutdown policy.
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
                let horizonIssue = resources.time.closeAdmission()
                let reporter = reporter
                let task = Task { await resources.finish(reporter: reporter, horizonIssue: horizonIssue) }
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
        reporter: DiagnosticReporter) async -> StartupRollback
    {
        let owners = systems
        return await Task {
            let cleanup = await stopAndClean(owners, leases: leases, reporter: reporter)
            for lease in leases {
                lease.close()
            }
            for system in owners {
                system.release()
            }
            return StartupRollback(cleanup: cleanup)
        }.value
    }

    private static func stopAndClean(
        _ systems: [AnyActivatedSystem], leases: [any AnySequentialLease],
        scheduler: DeadlineEngine? = nil, reporter: DiagnosticReporter) async -> [AttachmentCleanup]
    {
        for system in systems.reversed() {
            await system.beginFinalization()
        }
        await scheduler?.drain()
        for system in systems {
            await system.quiesce()
        }
        for lease in leases {
            await lease.join()
        }
        return await cleanUp(systems, reporter: reporter)
    }

    private static func cleanUp(
        _ systems: [AnyActivatedSystem], reporter: DiagnosticReporter)
        async -> [AttachmentCleanup]
    {
        var outcomes: [AttachmentCleanup] = []
        for system in systems.reversed() {
            let disposition: AttachmentCleanup.Disposition
            do {
                try await system.deactivate()
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
