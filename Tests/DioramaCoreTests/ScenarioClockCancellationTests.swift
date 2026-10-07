@testable import DioramaCore
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ScenarioClockCancellationTests {
    @Test
    func `already canceled task never registers a timer`() async throws {
        let source = SchedulerTestClock()
        let (execution, _) = try SchedulerFixtures.setup([], clock: source.source)
        let clock = execution.context.clock
        let sleeper = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(until: .init(offset: .seconds(10)))
        }
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(source.maximumWaits == 0)
        #expect(await execution.finish().report.diagnostics.isEmpty)
    }

    @Test
    func `pending task cancellation removes the timer and resumes exactly once`() async throws {
        let source = SchedulerTestClock()
        let (execution, _) = try SchedulerFixtures.setup([], clock: source.source)
        let clock = execution.context.clock
        let sleeper = Task { try await clock.sleep(until: .init(offset: .seconds(10))) }
        let wait = try await source.nextSleep()
        sleeper.cancel()
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(try await source.nextCancellation() == .seconds(10))
        wait.resume.finish()
        source.advance(to: .seconds(20))
        #expect(await execution.finish().report.diagnostics.isEmpty)
        #expect(source.activeWaits == 0)
    }

    @Test
    func `claimed sleep survives task cancellation and finish before handoff`() async throws {
        let source = SchedulerTestClock()
        let timerExit = ClockTimerExitGate()
        defer { timerExit.release() }
        let driver = ExecutionClock(now: source.source.now, sleep: { deadline, tolerance in
            do {
                try await source.source.sleep(deadline, tolerance)
            } catch {
                await timerExit.suspend()
                throw error
            }
        })
        let (execution, systems) = try SchedulerFixtures.setup(clock: driver)
        let clock = execution.context.clock
        let sleeper = Task { try await clock.sleep(until: .init(offset: .seconds(1))) }
        _ = try await source.nextSleep()
        source.advance(to: .seconds(1), waking: false)
        // Registration wakes the worker. It claims the due sleep before
        // canceling and joining the old timer, whose exit is held below.
        try systems[0].scheduling.schedule(at: .seconds(2), for: SchedulerFixtures.record()) {
            Issue.record("Pending attachment work must be canceled by finish")
        }
        await timerExit.waitForEntry()
        sleeper.cancel()
        let stopped = SchedulerJournal()
        try registerShutdownMarker(on: systems[0].scheduling, journal: stopped)
        let finish = Task { await execution.finish() }
        #expect(await stopped.take(1) == ["stopped"])
        timerExit.release()
        try await sleeper.value
        #expect(await finish.value.report.diagnostics.isEmpty)
    }

    @Test
    func `finish owns queued cancellation while the worker is joining a timer`() async throws {
        let source = SchedulerTestClock()
        let timerExit = ClockTimerExitGate()
        defer { timerExit.release() }
        let driver = ExecutionClock(now: source.source.now, sleep: { deadline, tolerance in
            do {
                try await source.source.sleep(deadline, tolerance)
            } catch {
                await timerExit.suspend()
                throw error
            }
        })
        let (execution, systems) = try SchedulerFixtures.setup(clock: driver)
        let clock = execution.context.clock
        let sleeper = Task { try await clock.sleep(until: .init(offset: .seconds(20))) }
        _ = try await source.nextSleep()
        try systems[0].scheduling.schedule(at: .seconds(10), for: SchedulerFixtures.record()) {
            Issue.record("Pending attachment delivery must not run")
        }
        await timerExit.waitForEntry()
        sleeper.cancel()
        let finish = Task { await execution.finish() }
        // Completion does not depend on the stopped worker reaching another
        // drain, or on the canceled application's cancellation handler resuming.
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        timerExit.release()
        #expect(await finish.value.report.diagnostics.isEmpty)
    }

    @Test
    func `finish freezes admission horizon before delivery drains and cancels pending sleeps`() async throws {
        let source = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: source.source)
        let gate = SchedulerDeliveryGate()
        defer { gate.release() }
        try systems[0].scheduling.schedule(at: .zero, for: SchedulerFixtures.record()) {
            await gate.suspend()
        }
        await gate.waitForEntry()
        let clock = execution.context.clock
        let sleeper = Task { try await clock.sleep(until: .init(offset: .seconds(20))) }
        _ = try await source.nextSleep()
        source.advance(to: .seconds(7), waking: false)
        let finish = Task { await execution.finish() }
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        _ = try await source.nextCancellation()
        source.advance(to: .seconds(100))
        #expect(clock.now.offset == .seconds(7))
        let repeated = Task { await execution.finish() }
        finish.cancel()
        repeated.cancel()
        gate.release()
        let result = await finish.value
        #expect(await repeated.value.report == result.report)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.logicalTime(.executionClosed)])
        #expect(clock.now.offset == .seconds(7))
        do {
            try await clock.sleep(until: .init(offset: .zero))
            Issue.record("A closed clock must reject even a past deadline")
        } catch let failure as SchedulingFailure {
            #expect(failure.diagnostic.issue == .scheduling(.logicalTime(.executionClosed)))
            #expect(failure.diagnostic.context == .scenario)
        }
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(until: .init(offset: .zero))
        }
        await #expect(throws: SchedulingFailure.self) { try await canceled.value }
        #expect(execution.reporter.postFinishDiagnostics.count == 3)
        #expect(await execution.finish().report == result.report)
        #expect(source.activeWaits == 0)
    }

    @Test(arguments: [false, true])
    func `concurrent sleeps race cancellation and execution closure without stranding waiters`(finishing: Bool)
        async throws
    {
        let source = SchedulerTestClock()
        let (execution, _) = try SchedulerFixtures.setup([], clock: source.source)
        let clock = execution.context.clock
        let sleepers = (0..<64).map { _ in
            Task { () -> Int in
                do {
                    try await clock.sleep(until: .init(offset: .seconds(1)))
                    return 1
                } catch is CancellationError {
                    return 2
                } catch let failure as SchedulingFailure {
                    #expect(finishing)
                    #expect(failure.diagnostic.issue == .scheduling(.logicalTime(.executionClosed)))
                    return 3
                } catch {
                    Issue.record(error)
                    return 0
                }
            }
        }
        _ = try await source.nextSleep()
        await withTaskGroup(of: Void.self) { group in
            for sleeper in sleepers {
                group.addTask { sleeper.cancel() }
            }
            group.addTask { source.advance(to: .seconds(1)) }
            if finishing {
                group.addTask { _ = await execution.finish() }
            }
        }
        var results: [Int] = []
        for sleeper in sleepers {
            await results.append(sleeper.value)
        }
        #expect(results.count == 64 && results.allSatisfy { (1...3).contains($0) })
        let final = await execution.finish()
        #expect(final.report.recordingHealth.isHealthy)
        #expect(final.usage.isEmpty)
        #expect(source.activeWaits == 0)
    }

    private func registerShutdownMarker(on scheduling: SchedulingLease, journal: SchedulerJournal) throws {
        let marker = SchedulerReleaseMarker { journal.append("stopped") }
        try scheduling.schedule(at: .seconds(100), for: SchedulerFixtures.record(sequence: 1)) {
            withExtendedLifetime(marker) { _ = Issue.record("Pending work must not run") }
        }
    }
}

/// Unlike a timer or AsyncStream iterator, this controlled join ignores task cancellation.
private final class ClockTimerExitGate: Sendable {
    private enum State {
        case ready
        case waiting(CheckedContinuation<Void, Never>)
        case released
    }

    private let state = Mutex(State.ready)
    private let entry = AsyncStream<Void>.makeStream()

    func suspend() async {
        await withCheckedContinuation { continuation in
            let released = state.withLock { state in
                if case .released = state {
                    return true
                }
                state = .waiting(continuation)
                return false
            }
            entry.continuation.finish()
            if released {
                continuation.resume()
            }
        }
    }

    func waitForEntry() async {
        for await _ in entry.stream {}
    }

    func release() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            let previous = state
            state = .released
            if case let .waiting(value) = previous {
                return value
            }
            return nil
        }
        continuation?.resume()
    }
}
