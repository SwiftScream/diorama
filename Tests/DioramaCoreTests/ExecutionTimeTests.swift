@testable import DioramaCore
import Synchronization
import Testing

private final class ControlledClock: Sendable {
    let instant: Mutex<ContinuousClock.Instant>
    let reads = Mutex(0)

    init() {
        instant = Mutex(ContinuousClock().now)
    }

    func now() -> ContinuousClock.Instant {
        reads.withLock { $0 += 1 }
        return instant.withLock { $0 }
    }

    func advance(by duration: Duration) {
        instant.withLock { $0 = $0.advanced(by: duration) }
    }
}

private final class EventJournal: Sendable {
    let events = Mutex<[String]>([])

    func append(_ event: String) {
        events.withLock { $0.append(event) }
    }
}

private final class TimeHolder: Sendable {
    let value = Mutex<ExecutionTime?>(nil)
}

private final class IssueJournal: Sendable {
    let issues = Mutex<[DiagnosticIssue]>([])

    func append(_ issue: DiagnosticIssue) {
        issues.withLock { $0.append(issue) }
    }
}

struct ExecutionTimeTests {
    private func system(_ key: String, definition: ScenarioDefinition,
                        events: EventJournal? = nil) throws -> AnyScenarioSystem
    {
        let attachment = definition.attachments.first { $0.id.key.rawValue == key }!
        return try AnyScenarioSystem(ScenarioSystem(
            type: ExecutionFixtures.type, attachment: attachment)
        { context in
            events?.append("prepare-\(key)")
            _ = try context.lease(for: ExecutionFixtures.track(key), preparation: ValuePreparation<Int>())
            let time = context.time
            return PreparedSystem {
                events?.append("activate-\(key)")
                return ActivatedSystem(dependency: time, deactivate: {})
            }
        })
    }

    private func start(_ keys: [String], clock: ControlledClock,
                       modes: [ScenarioMode?] = []) throws -> ScenarioExecution
    {
        let definition = try ExecutionFixtures.definition(keys)
        let systems = try keys.enumerated().map { index, key in
            let system = try ScenarioSystem(
                type: ExecutionFixtures.type,
                attachment: definition.attachments[index])
            { context in
                _ = try context.lease(for: ExecutionFixtures.track(key), preparation: ValuePreparation<Int>())
                let time = context.time
                return PreparedSystem { ActivatedSystem(dependency: time, deactivate: {}) }
            }
            return AnyScenarioSystem(system.withMode(index < modes.count ? modes[index] : nil))
        }
        return try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "time"),
            defaultMode: .record, systems: systems, clockNow: { clock.now() })
    }

    @Test
    func `origin starts after every activation and is shared by attachments`() async throws {
        let clock = ControlledClock()
        let events = EventJournal()
        let definition = try ExecutionFixtures.definition(["a", "b"])
        let systems = try ["b", "a"].map { try system($0, definition: definition, events: events) }
        let execution = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "time"),
            defaultMode: .record, systems: systems,
            clockNow: {
                events.append("clock-read")
                return clock.now()
            })
        #expect(events.events.withLock { $0 } == [
            "prepare-a", "prepare-b", "activate-a", "activate-b", "clock-read",
        ])
        #expect(clock.reads.withLock { $0 } == 1)
        let first = try execution.dependency(ExecutionFixtures.dependencyKey("a", as: ExecutionTime.self))
        let second = try execution.dependency(ExecutionFixtures.dependencyKey("b", as: ExecutionTime.self))
        #expect(first === second)
        #expect(try first.logicalNow() == .zero)
        clock.advance(by: .milliseconds(25))
        #expect(try second.logicalNow() == .milliseconds(25))
        _ = await execution.finish()
    }

    @Test
    func `activation sees no origin and failed startup never reads the clock`() throws {
        let clock = ControlledClock()
        let holder = TimeHolder()
        let earlyIssues = IssueJournal()
        let definition = try ExecutionFixtures.definition(["a"])
        let system = try ScenarioSystem<ExecutionTime>(type: ExecutionFixtures.type,
                                                       attachment: definition.attachments[0])
        { context in
            _ = try context.lease(for: ExecutionFixtures.track("a"), preparation: ValuePreparation<Int>())
            let time = context.time
            holder.value.withLock { $0 = time }
            return PreparedSystem<ExecutionTime> {
                do {
                    _ = try time.logicalNow()
                    Issue.record("Activation must not see a started clock")
                } catch let error as ExecutionTimeFailure {
                    earlyIssues.append(error.diagnostic.issue)
                }
                throw ExecutionFixtures.SecretError(journal: ExecutionFixtures.Journal())
            }
        }
        #expect(throws: ScenarioStartupFailure.self) {
            try ScenarioExecution.start(
                definition: definition, scenarioID: ScenarioID(rawValue: "time"),
                defaultMode: .record, systems: [AnyScenarioSystem(system)],
                clockNow: { clock.now() })
        }
        #expect(earlyIssues.issues.withLock { $0 } == [.logicalTime(.notStarted)])
        #expect(clock.reads.withLock { $0 } == 0)
        let escaped = holder.value.withLock { $0 }
        #expect(escaped != nil)
        do {
            _ = try escaped?.capture()
            Issue.record("Failed startup must close its time service")
        } catch {
            #expect(error.diagnostic.issue == .logicalTime(.executionClosed))
        }
    }

    @Test
    func `captures retain observation time and order before slow conversion`() async throws {
        let clock = ControlledClock()
        let execution = try start(["a"], clock: clock)
        let time = try execution.dependency(ExecutionFixtures.dependencyKey("a", as: ExecutionTime.self))
        clock.advance(by: .milliseconds(10))
        let first = try time.capture()
        clock.advance(by: .milliseconds(30))
        let second = try time.capture()

        // Later conversion of the first observation cannot change its capture.
        #expect(try time.logicalTime(at: first) == .milliseconds(10))
        #expect(try time.logicalTime(at: second) == .milliseconds(40))
        #expect(try time.elapsed(from: first, to: second) == .milliseconds(30))
        #expect(try time.capturedBefore(first, second))
        #expect(try !time.capturedBefore(second, first))
        #expect(try time.logicalTime(after: .milliseconds(5), from: first) == .milliseconds(15))
        _ = await execution.finish()
    }

    @Test
    func `mixed modes share a clock while executions have independent origins`() async throws {
        let clock = ControlledClock()
        let first = try start(["record", "replay", "passthrough"], clock: clock,
                              modes: [.record, .replay, .passthrough])
        let record = try first.dependency(ExecutionFixtures.dependencyKey("record", as: ExecutionTime.self))
        let replay = try first.dependency(ExecutionFixtures.dependencyKey("replay", as: ExecutionTime.self))
        let passthrough = try first.dependency(ExecutionFixtures.dependencyKey("passthrough", as: ExecutionTime.self))
        #expect(record === replay && replay === passthrough)
        clock.advance(by: .milliseconds(20))
        let firstCapture = try record.capture()

        let second = try start(["other"], clock: clock)
        let other = try second.dependency(ExecutionFixtures.dependencyKey("other", as: ExecutionTime.self))
        #expect(try other.logicalNow() == .zero)
        clock.advance(by: .milliseconds(7))
        #expect(try record.logicalNow() == .milliseconds(27))
        #expect(try other.logicalNow() == .milliseconds(7))
        let otherCapture = try other.capture()
        #expect(throws: ExecutionTimeFailure.self) {
            try record.elapsed(from: firstCapture, to: otherCapture)
        }
        _ = await first.finish()
        _ = await second.finish()
    }

    @Test
    func `concurrent captures keep monotonic order`() async throws {
        let execution = try start(["a"], clock: ControlledClock())
        let time = try execution.dependency(ExecutionFixtures.dependencyKey("a", as: ExecutionTime.self))
        let captures = try await withThrowingTaskGroup(of: LogicalTimeCapture.self) { group in
            for _ in 0..<64 {
                group.addTask { try time.capture() }
            }
            var values: [LogicalTimeCapture] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }
        var orderedPairs = 0
        for first in captures {
            for second in captures where try time.capturedBefore(first, second) {
                orderedPairs += 1
                #expect(try time.logicalTime(at: first) <= time.logicalTime(at: second))
            }
        }
        #expect(orderedPairs == 64 * 63 / 2)
        _ = await execution.finish()
    }

    @Test
    func `invalid intervals and arithmetic fail with safe diagnostics`() async throws {
        let clock = ControlledClock()
        let execution = try start(["a"], clock: clock)
        let time = try execution.dependency(ExecutionFixtures.dependencyKey("a", as: ExecutionTime.self))
        let first = try time.capture()
        clock.advance(by: .seconds(1))
        let second = try time.capture()
        do {
            _ = try time.elapsed(from: second, to: first)
            Issue.record("Reversed captures must fail")
        } catch {
            #expect(error.diagnostic.issue == .logicalTime(.reversedCaptures))
        }
        do {
            _ = try time.logicalTime(after: .milliseconds(-1), from: first)
            Issue.record("Negative delays must fail")
        } catch {
            #expect(error.diagnostic.issue == .logicalTime(.negativeDelay))
        }
        do {
            _ = try time.logicalTime(after: .seconds(Int64.max), from: second)
            Issue.record("Overflow must fail")
        } catch {
            #expect(error.diagnostic.issue == .logicalTime(.overflow))
        }
        _ = await execution.finish()
    }

    @Test
    func `backward source and closed execution reject new reads`() async throws {
        let clock = ControlledClock()
        let execution = try start(["a"], clock: clock)
        let time = try execution.dependency(ExecutionFixtures.dependencyKey("a", as: ExecutionTime.self))
        clock.advance(by: .milliseconds(10))
        let token = try time.capture()
        clock.advance(by: .milliseconds(-1))
        do {
            _ = try time.logicalNow()
            Issue.record("A backward source must fail")
        } catch {
            #expect(error.diagnostic.issue == .logicalTime(.clockMovedBackward))
        }
        clock.advance(by: .milliseconds(1))
        #expect(try time.logicalTime(at: token) == .milliseconds(10))
        let result = await execution.finish()
        do {
            _ = try time.capture()
            Issue.record("A closed execution must reject capture")
        } catch {
            #expect(error.diagnostic.issue == .logicalTime(.executionClosed))
        }
        #expect(result.report.diagnostics.count == 1)
        #expect(result.evaluate(.noUnexpectedOperations).failures.count == 1)
        #expect(execution.reporter.postFinishDiagnostics.count == 1)
    }
}
