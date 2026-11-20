import DioramaCore

/// Attachment-owned replay of strictly admitted HTTP interactions.
/// Retain this controller in replay mode and call `close()` from the mode's requestStop hook.
public actor HTTPInteractionReplay<Failure: Sendable> {
    /// Await the actual handoff to the adapter. Decision presentation returns independently of the answer.
    public typealias Delivery = @Sendable (HTTPReplayEvent<Failure>) async -> Void

    private typealias Interaction = HTTPInteraction<Failure>
    private typealias Step = HTTPReplayStep<Failure>

    /// Mutable only on this controller's actor. Each operation owns at most one scheduler registration.
    private final class Run {
        let claim: ReplayClaim<Interaction>
        let deliver: Delivery
        var anchor: LogicalTimeCapture
        var elapsed: Int64 = 0
        var progress: UInt64 = 0
        var steps: [Step]
        var barrier: HTTPReplayBarrier<Failure>?
        var pending: ScheduledItemHandle?
        var handingOff = false

        init(claim: ReplayClaim<Interaction>, deliver: @escaping Delivery, anchor: LogicalTimeCapture) throws {
            self.claim = claim
            self.deliver = deliver
            self.anchor = anchor
            steps = try Step.attempt(claim.record.value.result, request: claim.record.value.initialRequest).reversed()
        }
    }

    private struct Services: Sendable {
        let time: ExecutionTime
        let scheduling: SchedulingLease
        let reporter: DiagnosticReporter
        let matcher: HTTPRequestMatcher
        let isClosed: @Sendable () -> Bool
        let claim: @Sendable (PreparedValue<HTTPRequestMessage>) throws
            -> (LogicalTimeCapture, ReplayClaim<Interaction>)
    }

    private var services: Services?
    private var runs: [RecordIdentity: Run] = [:]

    /// Connects replay to the system's typed interaction lease, request equivalence, and execution services.
    public init<State>(execution: SystemExecution<State>,
                       track: KeyPath<State, SequentialTrackLease<HTTPInteraction<Failure>, some Sendable>> & Sendable,
                       matcher: HTTPRequestMatcher = .init())
    {
        let selector = matcher.selector { (record: Interaction) in matcher.projectOwned(record.initialRequest) }
        services = Services(
            time: execution.time, scheduling: execution.scheduling, reporter: execution.reporter,
            matcher: matcher, isClosed: { execution.isClosed }, claim: { request in
                try execution.state.withLock { state, operation in
                    let anchor = try operation.time.capture()
                    let projected = matcher.projectOwned(request.value)
                    let lease = state[keyPath: track]
                    return try (anchor, operation.claim(on: lease, matching: projected, using: selector))
                }
            })
    }

    /// Claims the earliest matching interaction once and queues its first reachable handoff.
    public func start(matching request: PreparedValue<HTTPRequestMessage>,
                      deliver: @escaping Delivery) throws -> HTTPReplayOperation
    {
        guard let services else { throw HTTPReplayError.inactive }
        let (anchor, claim) = try services.claim(request)
        let id = claim.record.identity
        let run = try Run(claim: claim, deliver: deliver, anchor: anchor)
        runs[id] = run
        try schedule(run)
        return HTTPReplayOperation(identity: id) { [weak self] in await self?.stop(id) }
    }

    /// Stops future handoffs and releases every pending operation, including unanswered decisions.
    public func close() {
        services = nil
        for run in runs.values {
            run.pending?.cancel()
        }
        runs.removeAll()
    }

    private func stop(_ id: RecordIdentity) {
        runs.removeValue(forKey: id)?.pending?.cancel()
    }

    private func schedule(_ run: Run) throws {
        guard let services, !run.handingOff, run.barrier == nil else { return }
        let id = run.claim.record.identity
        guard let step = run.steps.popLast() else {
            // An empty continuation reaches an open horizon. Keep the pending operation
            // attached until caller cancellation or the owning system stops.
            run.claim.markConsumed()
            return
        }
        do {
            run.elapsed = try HTTPDelay.add(run.elapsed, step.delay)
            let deadline = try services.time.logicalTime(after: .milliseconds(run.elapsed), from: run.anchor)
            run.pending = try services.scheduling.schedule(at: deadline, for: id) { [weak self] in
                await self?.deliver(step.action, id: id)
            }
        } catch {
            stop(id)
            throw error
        }
    }

    private func deliver(_ action: Step.Action, id: RecordIdentity) async {
        guard let run = runs[id], let services, !services.isClosed() else { return }
        run.pending = nil
        run.handingOff = true
        let sequence = run.progress + 1
        let event: HTTPReplayEvent<Failure>
        let reachesEnd: Bool
        switch action {
        case let .emit(value):
            event = value
            reachesEnd = run.steps.isEmpty
        case let .decision(barrier):
            run.barrier = barrier
            reachesEnd = barrier.isHorizon
            event = presentation(barrier, id: id, sequence: sequence)
        }
        await run.deliver(event)
        run.progress = sequence
        run.claim.advance(to: sequence)
        run.handingOff = false
        if reachesEnd || (run.barrier == nil && run.steps.isEmpty) {
            run.claim.markConsumed()
            switch event {
            case .returned, .failed: stop(id)
            default: break
            }
            return
        }
        guard runs[id] === run, !services.isClosed() else { return }
        do {
            try schedule(run)
        } catch {
            // The failed run is removed. This delivery scope remains joined through the terminal handoff.
            guard !services.isClosed() else { return }
            await run.deliver(.infrastructureFailure(.schedulingFailed))
        }
    }

    private func presentation(_ barrier: HTTPReplayBarrier<Failure>, id: RecordIdentity,
                              sequence: UInt64) -> HTTPReplayEvent<Failure>
    {
        switch barrier {
        case let .redirect(phase):
            .redirect(phase.proposedRequest, answer(id, sequence, HTTPReplayDecision.redirect))
        case let .auth(phase, _):
            .authenticate(phase.challenge, answer(id, sequence, HTTPReplayDecision.auth))
        case .disposition:
            .disposition(answer(id, sequence, HTTPReplayDecision.disposition))
        }
    }

    private func answer<D>(_ id: RecordIdentity, _ sequence: UInt64,
                           _ wrap: @escaping @Sendable (D) -> HTTPReplayDecision) -> HTTPReplayAnswer<D>
    {
        HTTPReplayAnswer { [weak self, weak time = services?.time] decision in
            guard let self, let time else { throw HTTPReplayError.inactive }
            let anchor = try time.capture()
            try await resume(wrap(decision.value), at: anchor, id: id, sequence: sequence)
        }
    }

    private func resume(_ decision: HTTPReplayDecision, at anchor: LogicalTimeCapture,
                        id: RecordIdentity, sequence: UInt64) throws
    {
        guard let services, !services.isClosed(), let run = runs[id], let barrier = run.barrier,
              sequence == (run.handingOff ? run.progress + 1 : run.progress)
        else {
            throw HTTPReplayError.inactive
        }
        do {
            run.steps = try barrier.select(decision, matcher: services.matcher).reversed()
        } catch {
            let beyond = barrier.isHorizon
            let label = DiagnosticLabel(beyond ? "http.decision.beyondHorizon" : "http.decision.mismatch")
            services.reporter.record(Diagnostic(issue: .system(label), context: .record(id)))
            stop(id)
            throw beyond ? HTTPReplayError.decisionBeyondRecordingHorizon : HTTPReplayError.incompatibleDecision
        }
        run.barrier = nil
        run.anchor = anchor
        run.elapsed = 0
        try schedule(run)
    }
}
