@testable import DioramaCore
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ScenarioClockLifetimeTests {
    private enum SourceFailure: Error { case failed }

    @Test
    func `timer failure releases pending sleepers with safe already reported errors`() async throws {
        let source = SchedulerTestClock()
        let driver = ExecutionClock(now: source.source.now, sleep: { _, _ in throw SourceFailure.failed })
        let (execution, _) = try SchedulerFixtures.setup([], clock: driver)
        for _ in 0..<2 {
            do {
                try await execution.context.clock.sleep(until: .init(offset: .seconds(1)))
                Issue.record("A failed timer must fail the sleep")
            } catch let failure as SchedulingFailure {
                #expect(failure.diagnostic.issue == .scheduling(.clockWaitFailed))
                #expect(failure.diagnostic.context == .scenario)
            }
        }
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .scheduling(.clockWaitFailed), .scheduling(.clockWaitFailed),
        ])
    }

    @Test
    func `host deadline overflow is a safe registration failure`() async throws {
        let (execution, _) = try SchedulerFixtures.setup([])
        do {
            try await execution.context.clock.sleep(until: .init(offset: .maximumLogicalTime))
            Issue.record("Logical maximum cannot map beyond the host timer range")
        } catch let failure as SchedulingFailure {
            #expect(failure.diagnostic.issue == .scheduling(.logicalTime(.overflow)))
        }
        #expect(await execution.finish().report.diagnostics.count == 1)
    }

    @Test
    func `nonthrowing now falls back before startup and after failed startup`() async throws {
        let source = SchedulerTestClock()
        let escaped = Mutex<ScenarioClock?>(nil)
        let definition = try ExecutionFixtures.definition(["a"])
        let system = try ScenarioSystem<ScenarioClock>(type: ExecutionFixtures.type,
                                                       attachment: definition.attachments[0])
        { context in
            _ = try context.lease(for: ExecutionFixtures.track("a"), preparation: ValuePreparation<Int>())
            let clock = context.clock
            escaped.withLock { $0 = clock }
            #expect(clock.now.offset == .zero)
            return PreparedSystem<ScenarioClock> { throw SourceFailure.failed }
        }
        do {
            _ = try ScenarioExecution.start(
                definition: definition, scenarioID: ScenarioID(rawValue: "rollback-clock"),
                defaultMode: .record, systems: [AnyScenarioSystem(system)], clock: source.source)
            Issue.record("Activation must fail")
        } catch let failure {
            #expect(failure.report.diagnostics.contains { $0.diagnostic.issue == .logicalTime(.notStarted) })
        }
        let clock = try #require(escaped.withLock { $0 })
        source.advance(to: .seconds(10))
        #expect(clock.now.offset == .zero)
        await #expect(throws: SchedulingFailure.self) { try await clock.sleep(for: .seconds(1)) }
        #expect(source.maximumWaits == 0)
    }

    @Test
    func `failed now and horizon preserve last valid time with reentrant diagnostics`() async throws {
        let source = SchedulerTestClock()
        let escaped = Mutex<ScenarioClock?>(nil)
        let resolutions = Mutex<[Duration]>([])
        let (execution, _) = try SchedulerFixtures.setup([], clock: source.source, sink: DiagnosticSink { _ in
            // Reenter a property without recursively generating another issue.
            if let clock = escaped.withLock({ $0 }) {
                resolutions.withLock { $0.append(clock.minimumResolution) }
            }
        })
        let clock = execution.context.clock
        escaped.withLock { $0 = clock }
        source.advance(to: .seconds(5))
        #expect(clock.now.offset == .seconds(5))
        source.advance(to: .seconds(4))
        #expect(clock.now.offset == .seconds(5))
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .logicalTime(.clockMovedBackward), .logicalTime(.clockMovedBackward),
        ])
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(result.definition == nil)
        source.advance(to: .seconds(100))
        #expect(clock.now.offset == .seconds(5))
        #expect(resolutions.withLock { $0.count } == 3)
        #expect(execution.reporter.postFinishDiagnostics.count == 1)
    }

    @Test
    func `escaped context and sleeping task do not retain the deadline engine`() async throws {
        let source = SchedulerTestClock()
        let reporter = try DiagnosticReporter(scenarioID: ScenarioID(rawValue: "clock-lifetime"),
                                              definition: ScenarioDefinition())
        let admission = ExecutionAdmission()
        let retainedTime = ExecutionTime(clock: source.source, admission: admission, reporter: reporter)
        var engine: DeadlineEngine? = DeadlineEngine(time: retainedTime, admission: admission, reporter: reporter)
        weak let weakEngine = engine
        let context = try ScenarioExecutionContext(
            clock: ScenarioClock(time: retainedTime, scheduler: #require(engine), reporter: reporter))
        retainedTime.start()
        let sleeper = Task { try await context.clock.sleep(until: .init(offset: .seconds(10))) }
        _ = try await source.nextSleep()
        source.advance(to: .seconds(3), waking: false)
        #expect(retainedTime.closeAdmission() == nil)
        await engine?.stop()?.value
        retainedTime.close()
        engine = nil
        // The canceled application's continuation may not have resumed yet.
        // Neither its suspended frame nor the escaped context may own the engine.
        #expect(weakEngine == nil)
        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(context.clock.now.offset == .seconds(3))
    }

    @Test
    func `finished execution releases injected source captures while context escapes`() async throws {
        let journal = SchedulerJournal()
        let execution = try startWithSourceMarker(journal: journal)
        let context = execution.context
        #expect(journal.values.isEmpty)
        let result = await execution.finish()
        #expect(journal.values == ["released"])
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.logicalTime(.executionClosed)])
        #expect(context.clock.minimumResolution > .zero)
        #expect(await execution.finish().report == result.report)
    }

    private func startWithSourceMarker(journal: SchedulerJournal) throws -> ScenarioExecution {
        // Copy the clock through a separately retainable reference for deinit
        // reentry without retaining any execution resources in the reporter.
        let box = ClockHolder()
        let marker = SchedulerReleaseMarker {
            _ = box.clock.withLock { $0 }?.now
            journal.append("released")
        }
        let source = ExecutionClock(now: {
            withExtendedLifetime(marker) { ContinuousClock().now }
        }, sleep: ExecutionClock.continuous().sleep)
        let (execution, _) = try SchedulerFixtures.setup([], clock: source)
        box.clock.withLock { $0 = execution.context.clock }
        return execution
    }
}

private final class ClockHolder: Sendable {
    let clock = Mutex<ScenarioClock?>(nil)
}
