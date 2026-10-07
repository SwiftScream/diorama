import Synchronization

/// One sleep bridges task cancellation to the scheduler's atomic claim rule.
final class ClockSleep: Sendable {
    private enum State {
        case ready
        case canceled
        case waiting(CheckedContinuation<Void, any Error>, ScheduledItemHandle)
        case finished
    }

    private let state = Mutex(State.ready)

    private enum Registration {
        case installed
        case canceled
        case failed(SchedulingIssue)
    }

    func wait(_ register: (CheckedContinuation<Void, any Error>) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    func register(_ continuation: CheckedContinuation<Void, any Error>, until deadline: Duration,
                  scheduler: DeadlineEngine, reporter: DiagnosticReporter)
    {
        let registration: Registration = state.withLock { state in
            if case .canceled = state {
                return .canceled
            }
            guard case .ready = state else { preconditionFailure("A sleep registers only once") }
            do throws(SchedulingIssue) {
                // Registration never invokes delivery or cancellation inline.
                // Keep installation atomic with the task's cancellation handler.
                let handle = try scheduler.registerSleep(at: deadline, sleep: self)
                state = .waiting(continuation, handle)
                return .installed
            } catch {
                state = .finished
                return .failed(error)
            }
        }
        switch registration {
        case .installed: break
        case .canceled:
            continuation.resume(throwing: CancellationError())
        case let .failed(issue):
            let diagnostic = Diagnostic(issue: .scheduling(issue))
            reporter.record(diagnostic)
            continuation.resume(throwing: SchedulingFailure(diagnostic: diagnostic))
        }
    }

    private func cancel() {
        let handle = state.withLock { state -> ScheduledItemHandle? in
            switch state {
            case .ready:
                state = .canceled
                return nil
            case let .waiting(_, handle): return handle
            case .canceled, .finished: return nil
            }
        }
        // Engine cancellation can complete this sleep; never call it under the
        // sleep's state lock. A claimed item refuses cancellation and succeeds.
        handle?.cancel()
    }

    func complete(_ result: Result<Void, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard case let .waiting(continuation, _) = state else { return nil }
            state = .finished
            return continuation
        }
        continuation?.resume(with: result)
    }
}
