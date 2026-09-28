import Synchronization

/// The host timer's representable instant range, after logical time is mapped
/// through this execution's origin.
private enum SchedulerTimerRange {
    private static let lastInstant = ContinuousClock().systemEpoch.advanced(by: .maximumLogicalTime)

    static func canRepresent(_ deadline: Duration, from origin: ContinuousClock.Instant) -> Bool {
        origin <= lastInstant.advanced(by: .zero - deadline)
    }
}

/// One worker owns the timer and hands off whole claimed batches serially.
final class DeadlineEngine: Sendable {
    private final class WaitIdentity: Sendable {}

    private enum Wake: Sendable {
        case changed
        case timer(WaitIdentity)
    }

    private struct Item: Sendable {
        let deadline: Duration
        let order: SchedulingOrder
        let registration: UInt64
        let handoff: @Sendable () -> Void

        static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.deadline != rhs.deadline {
                return lhs.deadline < rhs.deadline
            }
            if lhs.order != rhs.order {
                return lhs.order < rhs.order
            }
            return lhs.registration < rhs.registration
        }
    }

    private struct State: Sendable {
        var pending: [Item] = []
        var nextRegistration: UInt64 = 0
        var worker: Task<Void, Never>?
        var closed = false
        var failure: SchedulingIssue?
    }

    private struct Wait {
        let identity: WaitIdentity
        let deadline: Duration
        let task: Task<Bool, Never>
    }

    private enum Work {
        case batch([Item])
        case wait(Duration, ExecutionTimeReading)
        case idle
        case stopped
        case failed(SchedulingIssue)
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
                  handoff: @escaping @Sendable () -> Void) throws(SchedulingIssue)
    {
        let result: Result<Void, SchedulingIssue> = state.withLock { state in
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
            let item = Item(deadline: deadline, order: order,
                            registration: state.nextRegistration, handoff: handoff)
            state.nextRegistration += 1
            let index = state.pending.firstIndex { Item.precedes(item, $0) } ?? state.pending.endIndex
            state.pending.insert(item, at: index)
            if state.worker == nil {
                // The worker starts lazily, belongs to the execution, and is
                // joined at finish. Task creation cannot invoke a handoff inline.
                state.worker = Task { await self.run() }
            }
            return .success(())
        }
        try result.get()
        wake.continuation.yield(.changed)
    }

    /// Closes admission and transfers pending captures for destruction off-lock.
    /// Startup rollback calls this before the worker has started.
    func stop() -> Task<Void, Never>? {
        let detached = state.withLock { state in
            state.closed = true
            let detached = (state.worker, state.pending)
            state.worker = nil
            state.pending = []
            return detached
        }
        wake.continuation.finish()
        withExtendedLifetime(detached.1) {}
        return detached.0
    }

    private func takeWork() -> Work {
        state.withLock { state in
            guard !state.closed, !admission.isClosed else { return .stopped }
            guard let first = state.pending.first else { return .idle }
            let reading: ExecutionTimeReading
            switch time.schedulingSnapshot() {
            case let .success(value): reading = value
            case let .failure(issue): return .failed(issue)
            }
            guard first.deadline <= reading.time else { return .wait(first.deadline, reading) }
            let dueCount = state.pending.prefix { $0.deadline <= reading.time }.count
            let batch = Array(state.pending.prefix(dueCount))
            state.pending.removeFirst(dueCount)
            return .batch(batch)
        }
    }

    @concurrent
    private func run() async {
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
            if await !drain(wait: &wait) {
                break
            }
        }
        wait?.task.cancel()
        if await wait?.task.value == true {
            fail(.clockWaitFailed)
        }
    }

    private func drain(wait: inout Wait?) async -> Bool {
        while true {
            let work = takeWork()
            if case let .wait(deadline, _) = work, wait?.deadline == deadline {
                return true
            }
            wait?.task.cancel()
            let failed = await wait?.task.value == true
            wait = nil
            if failed {
                fail(.clockWaitFailed)
                return false
            }
            switch work {
            case let .batch(items):
                // All due items have left pending state before the first call.
                // Reentrant registration can only enter a subsequent batch.
                for item in items {
                    item.handoff()
                }
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
            let discarded = state.pending
            state.pending = []
            return discarded
        }
        reporter.record(Diagnostic(issue: .scheduling(issue)))
        withExtendedLifetime(discarded) {}
    }
}
