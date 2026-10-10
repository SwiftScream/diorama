@testable import DioramaCore
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ScenarioClockTests {
    @Test
    func `logical instants compare and perform signed subnanosecond arithmetic`() {
        let zero = ScenarioClock.Instant(offset: .zero)
        let before = zero.advanced(by: .seconds(-2))
        let fine = Duration(secondsComponent: 0, attosecondsComponent: 1)
        let after = zero.advanced(by: fine)
        #expect(before < zero && zero < after)
        #expect(before.duration(to: after) == .seconds(2) + fine)
        #expect(after.duration(to: before) == .seconds(-2) - fine)
        #expect(Set([zero, ScenarioClock.Instant(offset: .zero), before]).count == 2)
        let maximum = ScenarioClock.Instant(offset: .maximumLogicalTime)
        let minimum = ScenarioClock.Instant(offset: .zero - .maximumLogicalTime)
        #expect(maximum.advanced(by: .zero - .maximumLogicalTime) == zero)
        #expect(minimum.advanced(by: .maximumLogicalTime) == zero)
        #expect(zero.duration(to: maximum) == .maximumLogicalTime)
        #expect(zero.duration(to: minimum) == .zero - .maximumLogicalTime)
    }

    #if os(macOS) || os(Linux)
        @Test
        func `out of range construction advance and intervals fail preconditions`() async {
            await #expect(processExitsWith: .failure) {
                _ = ScenarioClock.Instant(offset: .seconds(Int64.max) * 2)
            }
            await #expect(processExitsWith: .failure) {
                _ = ScenarioClock.Instant(offset: .zero).advanced(by: .seconds(Int64.max) * 2)
            }
            await #expect(processExitsWith: .failure) {
                _ = ScenarioClock.Instant(offset: .maximumLogicalTime).advanced(by: .seconds(1))
            }
            await #expect(processExitsWith: .failure) {
                _ = ScenarioClock.Instant(offset: .zero - .maximumLogicalTime)
                    .duration(to: ScenarioClock.Instant(offset: .maximumLogicalTime))
            }
        }
    #endif

    @Test(arguments: [ScenarioMode.record, .replay, .passthrough])
    func `clock works without systems and creates no content or usage`(mode: ScenarioMode) async throws {
        let source = SchedulerTestClock()
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(), scenarioID: ScenarioID(rawValue: "clock-only"),
            defaultMode: mode, systems: [], clock: source.source)
        let clock = execution.context.clock
        #expect(clock.now.offset == .zero)
        #expect(clock.minimumResolution == source.source.minimumResolution)
        source.advance(to: .milliseconds(125))
        #expect(clock.now.offset == .milliseconds(125))
        try await clock.sleep(until: .init(offset: .milliseconds(-1)))
        let result = await execution.finish()
        #expect(result.definition?.attachments.isEmpty == true)
        #expect(result.usage.isEmpty)
        #expect(result.report.diagnostics.isEmpty)
        #expect(source.maximumWaits == 0)
        source.advance(to: .seconds(100))
        #expect(clock.now.offset == .milliseconds(125))
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.logicalTime(.executionClosed)])
    }

    @Test(arguments: [Duration?.none, .zero, .seconds(10)])
    func `sleep ignores larger tolerance and rechecks an early timer wake`(tolerance: Duration?) async throws {
        let source = SchedulerTestClock()
        let (execution, _) = try SchedulerFixtures.setup([], clock: source.source)
        let clock = execution.context.clock
        let completed = Mutex(false)
        let sleeper = Task {
            try await clock.sleep(until: .init(offset: .seconds(2)), tolerance: tolerance)
            completed.withLock { $0 = true }
        }
        let first = try await source.nextSleep()
        #expect(first.deadline == .seconds(2) && first.tolerance == .zero)
        source.advance(to: .seconds(1), early: true)
        #expect(try await source.nextSleep().deadline == .seconds(2))
        #expect(!completed.withLock { $0 })
        source.advance(to: .seconds(2))
        try await sleeper.value
        #expect(completed.withLock { $0 })
        #expect(await execution.finish().report.diagnostics.isEmpty)
        #expect(source.maximumWaits == 1)
    }

    @Test
    func `transferred instants use the receiving executions local origin`() async throws {
        let source = SchedulerTestClock()
        let (first, _) = try SchedulerFixtures.setup([], clock: source.source)
        source.advance(to: .seconds(10))
        let (second, _) = try SchedulerFixtures.setup([], clock: source.source)
        let deadline = first.context.clock.now.advanced(by: .seconds(20))
        #expect(deadline.offset == .seconds(30))
        #expect(second.context.clock.now.offset == .zero)
        let clock = second.context.clock
        let sleeper = Task { try await clock.sleep(until: deadline) }
        #expect(try await source.nextSleep().deadline == .seconds(40))
        #expect(await first.finish().report.diagnostics.isEmpty)
        source.advance(to: .seconds(40))
        try await sleeper.value
        #expect(clock.now == deadline)
        #expect(await second.finish().report.diagnostics.isEmpty)
    }

    @Test
    func `public system contexts receive the same clock in every mode`() async throws {
        let source = SchedulerTestClock()
        let definition = try ExecutionFixtures.definition(["record", "replay", "pass"])
        let modes: [ScenarioMode] = [.record, .replay, .passthrough]
        let systems = try definition.attachments.enumerated().map { index, attachment in
            try ScenarioSystem(type: ExecutionFixtures.type, attachment: attachment) { context in
                if context.mode != .passthrough {
                    _ = try context.lease(for: attachment.trackIDs[0], preparation: ValuePreparation<Int>())
                }
                let clock = context.clock
                return PreparedSystem { ActivatedSystem(dependency: clock, deactivate: {}) }
            }.withMode(modes[index])
        }
        let execution = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "shared-clock"),
            defaultMode: .record, systems: systems.map(AnyScenarioSystem.init), clock: source.source)
        source.advance(to: .milliseconds(123))
        for system in systems {
            #expect(try execution.dependency(system).now == execution.context.clock.now)
        }
        #expect(await execution.finish().report.diagnostics.isEmpty)
    }

    @Test
    @MainActor
    func `standard generic Clock sleep uses real time without requiring a wall system`() async throws {
        let (execution, _) = try SchedulerFixtures.setup([])
        let elapsed = try await sleepGenerically(on: execution.context.clock)
        #expect(elapsed >= .milliseconds(10))
        #expect(elapsed < .seconds(5))
        #expect(await execution.finish().report.diagnostics.isEmpty)
    }

    private func sleepGenerically(on clock: some Clock<Duration>) async throws -> Duration {
        let before = clock.now
        try await clock.sleep(for: .milliseconds(10))
        return before.duration(to: clock.now)
    }
}
