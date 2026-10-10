import Synchronization

struct ScheduledHandoffOrder: Comparable, Sendable {
    let deadline: Duration
    let position: SchedulingOrder
    let registration: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.deadline != rhs.deadline {
            return lhs.deadline < rhs.deadline
        }
        if lhs.position != rhs.position {
            return lhs.position < rhs.position
        }
        return lhs.registration < rhs.registration
    }
}

/// One worker owns the timer and hands off whole claimed batches serially.
final class DeadlineEngine: Sendable {
    /// The host timer's representable instant range, after logical time is mapped
    /// through this execution's origin.
    private enum SchedulerTimerRange {
        private static let lastInstant = ContinuousClock().systemEpoch.advanced(by: .maximumLogicalTime)

        static func canRepresent(_ deadline: Duration, from origin: ContinuousClock.Instant) -> Bool {
            origin <= lastInstant.advanced(by: .zero - deadline)
        }
    }

    private enum ScheduledWork: Sendable {
        case delivery(@Sendable () async -> Void)
        case sleep(ClockSleep)

        func cancel(with error: any Error) {
            if case let .sleep(sleep) = self {
                sleep.complete(.failure(error))
            }
        }
    }

    private struct Item: Sendable {
        let order: ScheduledHandoffOrder
        let registration: ScheduledRegistration
        let work: ScheduledWork
    }

    private struct State: Sendable {
        var pending: [Item] = []
        var canceledSleeps: [ClockSleep] = []
        var nextRegistration: UInt64 = 0
        var worker: Task<Void, Never>?
        var closed = false
        var failure: SchedulingIssue?
    }

    private enum Work {
        case batch([Item])
        case wait(Duration, ExecutionTimeReading)
        case idle
        case stopped
        case failed(SchedulingIssue)
    }

    private final class WaitIdentity: Sendable {}

    private enum Wake: Sendable {
        case changed
        case timer(WaitIdentity)
    }

    private struct Wait {
        let identity: WaitIdentity
        let deadline: Duration
        let task: Task<Bool, Never>
    }

    private let state = Mutex(State())
    private let wake = AsyncStream<Wake>.makeStream()
    private let time: ExecutionTime
    private let admission: ExecutionAdmission
    private let reporter: DiagnosticReporter

    init(time: ExecutionTime, admission: ExecutionAdmission, reporter: DiagnosticReporter) {
        self.time = time
        self.admission = admission
        self.reporter = reporter
    }

    func register(_ requested: SchedulingDeadline, order: SchedulingOrder,
                  delivery: @escaping @Sendable () async -> Void)
        throws(SchedulingIssue) -> ScheduledItemHandle
    {
        try register(requested, order: order, work: .delivery(delivery))
    }

    func registerSleep(at deadline: Duration, sleep: ClockSleep) throws(SchedulingIssue) -> ScheduledItemHandle {
        try register(.absolute(deadline), order: .execution, work: .sleep(sleep))
    }

    private func register(_ requested: SchedulingDeadline, order: SchedulingOrder, work: ScheduledWork)
        throws(SchedulingIssue) -> ScheduledItemHandle
    {
        let result: Result<ScheduledItemHandle, SchedulingIssue> = state.withLock { state in
            guard !state.closed, !admission.isClosed else { return .failure(.logicalTime(.executionClosed)) }
            if let failure = state.failure {
                return .failure(failure)
            }
            guard state.nextRegistration < UInt64.max else { return .failure(.registrationOverflow) }
            let reading: ExecutionTimeReading
            switch time.schedulingSnapshot() {
            case let .success(value): reading = value
            case let .failure(issue): return .failure(issue)
            }
            let deadline: Duration
            switch requested.resolve(now: reading.time) {
            case let .success(value): deadline = value
            case let .failure(issue): return .failure(.logicalTime(issue))
            }
            guard deadline <= reading.time || SchedulerTimerRange.canRepresent(deadline, from: reading.origin)
            else { return .failure(.logicalTime(.overflow)) }
            let registration = ScheduledRegistration(engine: self)
            let handoffOrder = ScheduledHandoffOrder(deadline: deadline, position: order,
                                                     registration: state.nextRegistration)
            let item = Item(order: handoffOrder, registration: registration, work: work)
            state.nextRegistration += 1
            let index = state.pending.firstIndex { item.order < $0.order } ?? state.pending.endIndex
            state.pending.insert(item, at: index)
            if state.worker == nil {
                // The worker starts lazily, belongs to the execution, and is
                // joined at finish. Task creation cannot invoke a handoff inline.
                state.worker = Task { await self.run() }
            }
            return .success(ScheduledItemHandle(registration: registration))
        }
        let handle = try result.get()
        wake.continuation.yield(.changed)
        return handle
    }

    /// Closes admission and transfers pending captures for destruction off-lock.
    /// Startup rollback calls this before the worker has started.
    func stop() -> Task<Void, Never>? {
        let detached = state.withLock { state in
            state.closed = true
            for item in state.pending {
                item.registration.transition(to: .canceled)
            }
            let detached = (state.worker, state.pending, state.canceledSleeps)
            state.worker = nil
            state.pending = []
            state.canceledSleeps = []
            return detached
        }
        wake.continuation.finish()
        for item in detached.1 {
            item.work.cancel(with: CancellationError())
        }
        for sleep in detached.2 {
            sleep.complete(.failure(CancellationError()))
        }
        withExtendedLifetime(detached.1) {}
        return detached.0
    }

    func cancel(_ registration: ScheduledRegistration) -> Bool {
        let removed = state.withLock { state -> Item? in
            guard let index = state.pending.firstIndex(where: { $0.registration === registration })
            else { return nil }
            registration.transition(to: .canceled)
            let item = state.pending.remove(at: index)
            if case let .sleep(sleep) = item.work {
                state.canceledSleeps.append(sleep)
            }
            return item
        }
        guard let removed else { return false }
        wake.continuation.yield(.changed)
        // The worker or stop owns canceled-sleep completion. A caller paused
        // here cannot resume a continuation after finalization has returned.
        // Capture destruction may reenter scheduling or reporting.
        if let effects = ManagedEffects.current {
            effects.append { withExtendedLifetime(removed) {} }
        } else {
            withExtendedLifetime(removed) {}
        }
        return true
    }

    private func complete(_ registration: ScheduledRegistration) {
        state.withLock { _ in registration.transition(to: .completed) }
    }

    private func deliver(_ items: [Item], tasks: inout DiscardingTaskGroup) {
        for item in items {
            let registration = item.registration
            switch item.work {
            case let .delivery(body):
                tasks.addTask {
                    await body()
                    self.complete(registration)
                }
            case let .sleep(sleep):
                sleep.complete(.success(()))
                complete(registration)
            }
        }
    }

    private func completeCancellations() {
        let canceled = state.withLock { state in
            let canceled = state.canceledSleeps
            state.canceledSleeps = []
            return canceled
        }
        for sleep in canceled {
            sleep.complete(.failure(CancellationError()))
        }
    }

    private func takeWork() -> Work {
        state.withLock { state in
            guard !state.closed, !admission.isClosed else { return .stopped }
            guard let first = state.pending.first else { return .idle }
            let reading: ExecutionTimeReading
            switch time.schedulingSnapshot() {
            case let .success(value): reading = value
            // Finish can close admission between the guard above and this
            // clock read. That is ordinary shutdown, not a clock failure.
            case .failure(.logicalTime(.executionClosed)): return .stopped
            case let .failure(issue): return .failed(issue)
            }
            guard first.order.deadline <= reading.time else { return .wait(first.order.deadline, reading) }
            let dueCount = state.pending.prefix { $0.order.deadline <= reading.time }.count
            let batch = Array(state.pending.prefix(dueCount))
            state.pending.removeFirst(dueCount)
            for item in batch {
                item.registration.transition(to: .claimed)
            }
            return .batch(batch)
        }
    }

    @concurrent
    private func run() async {
        await withDiscardingTaskGroup { tasks in
            await run(tasks: &tasks)
        }
        // Leaving the group joins all delivery scopes, including destruction
        // of their captures, before finish can freeze the report.
    }

    private func run(tasks: inout DiscardingTaskGroup) async {
        var wait: Wait?
        for await event in wake.stream {
            if case let .timer(identity) = event, wait?.identity === identity {
                let failed = await wait?.task.value == true
                wait = nil
                if failed {
                    fail(.clockWaitFailed)
                    break
                }
            }
            if await !drain(wait: &wait, tasks: &tasks) {
                break
            }
        }
        wait?.task.cancel()
        if await wait?.task.value == true {
            fail(.clockWaitFailed)
        }
    }

    private func drain(wait: inout Wait?, tasks: inout DiscardingTaskGroup) async -> Bool {
        while true {
            completeCancellations()
            let work = takeWork()
            if case let .wait(deadline, _) = work, wait?.deadline == deadline {
                return true
            }
            wait?.task.cancel()
            let failed = await wait?.task.value == true
            wait = nil
            if failed {
                fail(.clockWaitFailed)
                // A batch claimed before discovering the timer failure still
                // owns delivery. Pending work has been canceled by fail().
                if case let .batch(items) = work {
                    deliver(items, tasks: &tasks)
                }
                return false
            }
            switch work {
            case let .batch(items):
                // All due items have left pending state before the first call.
                // Reentrant registration can only enter a subsequent batch.
                deliver(items, tasks: &tasks)
            case let .wait(deadline, reading):
                wait = startWait(deadline: deadline, reading: reading)
                return true
            case .idle: return true
            case .stopped: return false
            case let .failed(issue):
                fail(issue)
                return false
            }
        }
    }

    private func startWait(deadline: Duration, reading: ExecutionTimeReading) -> Wait {
        let identity = WaitIdentity()
        let continuation = wake.continuation
        let task = Task {
            let failed: Bool
            do {
                try await reading.clock.sleep(reading.origin.advanced(by: deadline), .zero)
                failed = false
            } catch {
                failed = !Task.isCancelled
            }
            continuation.yield(.timer(identity))
            return failed
        }
        return Wait(identity: identity, deadline: deadline, task: task)
    }

    private func fail(_ issue: SchedulingIssue) {
        let discarded = state.withLock { state in
            state.failure = issue
            for item in state.pending {
                item.registration.transition(to: .canceled)
            }
            let discarded = (state.pending, state.canceledSleeps)
            state.pending = []
            state.canceledSleeps = []
            return discarded
        }
        let diagnostic = Diagnostic(issue: .scheduling(issue))
        reporter.record(diagnostic)
        for item in discarded.0 {
            item.work.cancel(with: SchedulingFailure(diagnostic: diagnostic))
        }
        for sleep in discarded.1 {
            sleep.complete(.failure(CancellationError()))
        }
        withExtendedLifetime(discarded) {}
    }
}
