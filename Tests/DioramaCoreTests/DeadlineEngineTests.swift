@testable import DioramaCore
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DeadlineEngineTests {
    @Test
    func `handoff keys sort overdue and equal deadlines deterministically`() async throws {
        let keys: [(ScheduledHandoffOrder, String)] = [
            (.init(deadline: .seconds(10), position: .init(attachment: 1, track: 0, record: 0), registration: 0), "a"),
            (.init(deadline: .seconds(10), position: .init(attachment: 0, track: 1, record: 0),
                   registration: 1), "z-second"),
            (.init(deadline: .seconds(10), position: .init(attachment: 0, track: 0, record: 3),
                   registration: 2), "z-3-first"),
            (.init(deadline: .seconds(10), position: .init(attachment: 0, track: 0, record: 1),
                   registration: 3), "z-1"),
            (.init(deadline: .seconds(10), position: .init(attachment: 0, track: 0, record: 3),
                   registration: 4), "z-3-second"),
            (.init(deadline: .seconds(5), position: .init(attachment: 1, track: 0, record: 9),
                   registration: 5), "earliest"),
        ]
        #expect(keys.sorted { $0.0 < $1.0 }.map(\.1) == [
            "earliest", "z-1", "z-3-first", "z-3-second", "z-second", "a",
        ])
        let clocks: [(ScheduledHandoffOrder, String)] = [
            (.init(deadline: .seconds(10), position: .execution, registration: 0), "clock-first"),
            (.init(deadline: .seconds(10), position: .execution, registration: 2), "clock-second"),
            (.init(deadline: .seconds(4), position: .execution, registration: 1), "clock-earliest"),
        ]
        #expect((clocks + keys).sorted { $0.0 < $1.0 }.map(\.1) == [
            "clock-earliest", "earliest", "z-1", "z-3-first", "z-3-second", "z-second", "a",
            "clock-first", "clock-second",
        ])

        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(["z", "a"], clock: clock.source)
        let journal = SchedulerJournal()
        let registrations: [(RecordIdentity, String)] = [
            (SchedulerFixtures.record("a"), "a"),
            (SchedulerFixtures.record("z", track: "a-second"), "z-second"),
            (SchedulerFixtures.record("z", sequence: 3), "z-3-first"),
            (SchedulerFixtures.record("z", sequence: 1), "z-1"),
            (SchedulerFixtures.record("z", sequence: 3), "z-3-second"),
        ]
        for (record, label) in registrations {
            let index = record.trackID.attachmentID.key.rawValue == "z" ? 0 : 1
            try systems[index].scheduling.schedule(at: .seconds(10), for: record) { journal.append(label) }
        }
        try systems[1].scheduling.schedule(at: .seconds(5), for: SchedulerFixtures.record("a", sequence: 9)) {
            journal.append("earliest")
        }
        // All registrations are admitted before one deliberately late wake.
        clock.advance(to: .seconds(30))
        #expect(await Set(journal.take(6)) == Set(keys.map(\.1)))
        #expect(clock.maximumWaits <= 1)
        #expect(await execution.finish().report.diagnostics.isEmpty)
    }

    @Test
    func `earlier insertion replaces the only wait and retains later work`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let lease = systems[0].scheduling
        let journal = SchedulerJournal()
        try lease.schedule(at: .seconds(30), for: SchedulerFixtures.record()) { journal.append("30") }
        let first = try await clock.nextSleep()
        #expect(first.deadline == .seconds(30))
        #expect(first.tolerance == .zero)
        try lease.schedule(at: .seconds(10), for: SchedulerFixtures.record()) { journal.append("10") }
        #expect(try await clock.nextCancellation() == .seconds(30))
        #expect(try await clock.nextSleep().deadline == .seconds(10))
        try lease.schedule(at: .seconds(40), for: SchedulerFixtures.record()) { journal.append("40") }
        clock.advance(to: .seconds(10))
        #expect(await journal.take(1) == ["10"])
        #expect(try await clock.nextSleep().deadline == .seconds(30))
        clock.advance(to: .seconds(45))
        #expect(await Set(journal.take(2)) == Set(["30", "40"]))
        _ = await execution.finish()
        #expect(clock.maximumWaits == 1)
        #expect(clock.activeWaits == 0)
    }

    @Test
    func `an early wake rechecks time without delivering before the deadline`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let journal = SchedulerJournal()
        try systems[0].scheduling.schedule(after: .seconds(10), for: SchedulerFixtures.record()) {
            journal.append("due")
        }
        #expect(try await clock.nextSleep().deadline == .seconds(10))
        clock.advance(to: .seconds(4), early: true)
        let replacement = try await clock.nextSleep()
        #expect(replacement.deadline == .seconds(10))
        #expect(replacement.tolerance == .zero)
        #expect(journal.values.isEmpty)
        clock.advance(to: .seconds(10))
        #expect(await journal.take(1) == ["due"])
        _ = await execution.finish()
    }

    @Test
    func `a complete due batch is claimed before reentrant registration`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let lease = systems[0].scheduling
        let journal = SchedulerJournal()
        let secondHandle = Mutex<ScheduledItemHandle?>(nil)
        try lease.schedule(at: .seconds(1), for: SchedulerFixtures.record(sequence: 1)) {
            let phase = secondHandle.withLock { $0 }?.registration.phase
            #expect(phase == .claimed || phase == .completed)
            journal.append("first-enter")
            do {
                try lease.schedule(at: .zero, for: SchedulerFixtures.record()) { journal.append("past") }
                try lease.schedule(at: .seconds(Int64.min), for: SchedulerFixtures.record()) {
                    journal.append("before-origin")
                }
                try lease.schedule(after: .zero, for: SchedulerFixtures.record()) { journal.append("zero") }
            } catch { Issue.record(error) }
            journal.append("first-return")
        }
        let second = try lease.schedule(at: .seconds(1), for: SchedulerFixtures.record(sequence: 2)) {
            journal.append("second")
        }
        secondHandle.withLock { $0 = second }
        clock.advance(to: .seconds(1))
        #expect(await Set(journal.take(6)) == Set([
            "first-enter", "first-return", "second", "before-origin", "past", "zero",
        ]))
        _ = await execution.finish()
    }

    @Test
    func `relative deadlines use the shared execution origin and checked addition`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let lease = systems[0].scheduling
        let journal = SchedulerJournal()
        clock.advance(to: .seconds(7))
        #expect(try systems[0].time.logicalNow() == .seconds(7))
        try lease.schedule(after: .seconds(3), for: SchedulerFixtures.record()) { journal.append("relative") }
        #expect(try await clock.nextSleep().deadline == .seconds(10))
        clock.advance(to: .seconds(10))
        #expect(await journal.take(1) == ["relative"])
        let invalid: [(SchedulingDeadline, ExecutionTimeIssue)] = [
            (.relative(.seconds(-1)), .negativeDelay),
            (.relative(.seconds(Int64.max)), .overflow),
            (.absolute(.seconds(Int64.max)), .overflow),
            (.absolute(.seconds(Int64.max) * 2), .overflow),
        ]
        for (request, expected) in invalid {
            do {
                switch request {
                case let .relative(delay):
                    try lease.schedule(after: delay, for: SchedulerFixtures.record()) { journal.append("invalid") }
                case let .absolute(deadline):
                    try lease.schedule(at: deadline, for: SchedulerFixtures.record()) { journal.append("invalid") }
                }
                Issue.record("Invalid timing must be rejected")
            } catch {
                #expect(error.diagnostic.issue == .scheduling(.logicalTime(expected)))
            }
        }
        let result = await execution.finish()
        #expect(result.evaluate(.noUnexpectedOperations).failures.count == 4)
        #expect(result.rendered().contains("scheduling-logical-time-overflow"))
        #expect(journal.values == ["relative"])
    }

    @Test
    func `concurrent registration hands off every admitted item exactly once`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let lease = systems[0].scheduling
        let journal = SchedulerJournal()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for sequence in 0..<64 {
                group.addTask {
                    try lease.schedule(at: .seconds(1), for: SchedulerFixtures.record(sequence: UInt64(sequence))) {
                        journal.append(String(sequence))
                    }
                }
            }
            try await group.waitForAll()
        }
        clock.advance(to: .seconds(1))
        #expect(await Set(journal.take(64)) == Set((0..<64).map(String.init)))
        _ = await execution.finish()
    }

    @Test
    func `finish joins the timer and closes escaped leases`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(clock: clock.source)
        let journal = SchedulerJournal()
        try systems[0].scheduling.schedule(at: .seconds(10), for: SchedulerFixtures.record()) {
            journal.append("unexpected")
        }
        _ = try await clock.nextSleep()
        let result = await execution.finish()
        #expect(clock.activeWaits == 0)
        clock.advance(to: .seconds(20))
        do {
            try systems[0].scheduling.schedule(after: .zero, for: SchedulerFixtures.record()) {
                journal.append("closed")
            }
            Issue.record("Finish must close scheduling")
        } catch {
            #expect(error.diagnostic.issue == .scheduling(.logicalTime(.executionClosed)))
        }
        #expect(journal.values.isEmpty)
        #expect(result.report.diagnostics.isEmpty)
        #expect(execution.reporter.postFinishDiagnostics.count == 1)
    }

    @Test
    func `undeclared and foreign tracks are rejected with attachment context`() async throws {
        let clock = SchedulerTestClock()
        let (execution, systems) = try SchedulerFixtures.setup(["a", "b"], clock: clock.source)
        for record in [SchedulerFixtures.record("b"), SchedulerFixtures.record(track: "missing")] {
            do {
                try systems[0].scheduling.schedule(at: .zero, for: record) { Issue.record("Invalid handoff") }
                Issue.record("Foreign and undeclared tracks must fail")
            } catch {
                #expect(error.diagnostic.issue == .scheduling(.invalidTrack))
                #expect(error.diagnostic.context == .attachment(ExecutionFixtures.attachment("a")))
            }
        }
        #expect(await execution.finish().evaluate(.noUnexpectedOperations).failures.count == 2)
    }
}
