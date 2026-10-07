@testable import DioramaCore
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SchedulingLifetimeTests {
    private enum ClockFailure: Error { case failed }

    private final class Marker: Sendable {
        let journal: SchedulerJournal

        init(_ journal: SchedulerJournal) {
            self.journal = journal
        }

        deinit { journal.append("released") }
    }

    @Test
    func `failed startup refuses scheduling and closes an escaped service`() throws {
        let holder = Mutex<SchedulingLease?>(nil)
        let definition = try ExecutionFixtures.definition(["a"])
        let system = try ScenarioSystem<SchedulingLease>(type: ExecutionFixtures.type,
                                                         attachment: definition.attachments[0])
        { context in
            _ = try context.lease(for: ExecutionFixtures.track("a"), preparation: ValuePreparation<Int>())
            let scheduling = context.scheduling
            holder.withLock { $0 = scheduling }
            do {
                try scheduling.schedule(after: .zero,
                                        for: RecordIdentity(trackID: ExecutionFixtures.track("a"), sequence: 0)) {}
                Issue.record("Preparation cannot schedule before the execution origin")
            } catch let failure as SchedulingFailure {
                #expect(failure.diagnostic.issue == .scheduling(.logicalTime(.notStarted)))
            }
            return PreparedSystem<SchedulingLease> { throw ClockFailure.failed }
        }
        #expect(throws: ScenarioStartupFailure.self) {
            try ScenarioExecution.start(definition: definition, scenarioID: ScenarioID(rawValue: "startup"),
                                        defaultMode: .replay, systems: [AnyScenarioSystem(system)])
        }
        let escaped = try #require(holder.withLock { $0 })
        do {
            try escaped.schedule(at: .zero, for: RecordIdentity(trackID: ExecutionFixtures.track("a"), sequence: 0)) {}
            Issue.record("Failed startup must close scheduling")
        } catch {
            #expect(error.diagnostic.issue == .scheduling(.logicalTime(.executionClosed)))
        }
    }

    @Test
    func `pending handoff captures leave the execution at finish`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let journal = SchedulerJournal()
        try registerMarker(on: systems[0].scheduling, journal: journal)
        _ = try await clock.nextSleep()
        #expect(journal.values.isEmpty)
        _ = await execution.finish()
        #expect(journal.values == ["released"])
    }

    private func registerMarker(on lease: SchedulingLease, journal: SchedulerJournal) throws {
        let marker = Marker(journal)
        try lease.schedule(after: .seconds(10), for: SchedulerFixtures.record()) {
            withExtendedLifetime(marker) { journal.append("unexpected-delivery") }
        }
    }

    @Test(arguments: [false, true])
    func `clock failures stop pending delivery and retain safe diagnostics`(backward: Bool) async throws {
        let clock = SchedulerTestClock()
        let diagnostics = AsyncStream<Diagnostic>.makeStream()
        let source = backward ? clock.source : ExecutionClock(now: clock.source.now, sleep: { _, _ in
            throw ClockFailure.failed
        })
        let (execution, systems) = try SchedulerFixtures.setup(clock: source, sink: DiagnosticSink {
            diagnostics.continuation.yield($0.diagnostic)
        })
        let journal = SchedulerJournal()
        try systems[0].scheduling.schedule(after: .seconds(1), for: SchedulerFixtures.record()) {
            journal.append("unexpected")
        }
        if backward {
            _ = try await clock.nextSleep()
            clock.advance(to: .seconds(-1), early: true)
        }
        var iterator = diagnostics.stream.makeAsyncIterator()
        let diagnostic = try #require(await iterator.next())
        let issue: SchedulingIssue = backward ? .logicalTime(.clockMovedBackward) : .clockWaitFailed
        #expect(diagnostic.issue == .scheduling(issue))
        do {
            try systems[0].scheduling.schedule(after: .zero, for: SchedulerFixtures.record()) {}
            Issue.record("A failed clock must not admit more work")
        } catch {
            #expect(error.diagnostic.issue == .scheduling(issue))
        }
        let result = await execution.finish()
        // A still-backward source also fails the newly stamped finish horizon.
        #expect(result.evaluate(.noUnexpectedOperations).failures.count == (backward ? 3 : 2))
        #expect(result.report.recordingHealth.isHealthy == !backward)
        #expect(result.rendered().contains(backward
                ? "scheduling-logical-time-clock-moved-backward" : "scheduling-clock-wait-failed"))
        #expect(journal.values.isEmpty)
        #expect(clock.activeWaits == 0)
    }

    @Test(arguments: [Duration.zero, .milliseconds(25)])
    @MainActor
    func `real clock hands off no earlier than its logical deadline`(delay: Duration) async throws {
        let (execution, systems) = try SchedulerFixtures.setup()
        let service = systems[0]
        let journal = SchedulerJournal()
        let deliveredAt = Mutex<Duration?>(nil)
        let start = try service.time.logicalNow()
        let deadline = start + delay
        try service.scheduling.schedule(at: deadline, for: SchedulerFixtures.record()) {
            do {
                let now = try service.time.logicalNow()
                deliveredAt.withLock { $0 = now }
            } catch { Issue.record(error) }
            journal.append("delivered")
        }
        #expect(await journal.take(1) == ["delivered"])
        let actual = try #require(deliveredAt.withLock { $0 })
        #expect(actual >= deadline)
        #expect(actual - start < .seconds(5))
        #expect(await execution.finish().report.diagnostics.isEmpty)
    }
}
