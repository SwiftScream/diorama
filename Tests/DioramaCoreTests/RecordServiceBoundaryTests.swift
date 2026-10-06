@testable import DioramaCore
import Dispatch
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RecordServiceBoundaryTests {
    @Test
    func `closing admission permits in flight progress until the record report freezes`() throws {
        let track = try SequentialTrack(id: SchedulerFixtures.record().trackID, values: preparedValues(["response"]))
        let admission = ExecutionAdmission()
        let reporter = try DiagnosticReporter(
            scenarioID: ScenarioID(rawValue: "draining"), definition: ScenarioDefinition())
        let lease = SequentialTrackLease(track: track, baseline: track.records, baselineHeader: (),
                                         mode: .replay, reporter: reporter, admission: admission)
        let claim = try lease.claim(matching: (), using: .sequential())
        admission.close()
        #expect(throws: SequentialOperationFailure.self) { try lease.consumeNext() }
        #expect(claim.advance(to: 1))
        #expect(claim.markConsumed())
        let closed = lease.close()
        #expect(closed.usage.claimedRecords.first?.isConsumed == true)
        #expect(!claim.advance(to: 2))
        #expect(!claim.markConsumed())
    }

    @Test
    func `plain values need no lifecycle protocol and selected claims share sequential availability`() async throws {
        let (execution, lease) = try RecordCaptureFixtures.start(mode: .replay, values: ["a", "b", "a", "c"])
        let exact = ReplaySelector<String, String>.exactInput { $0 }
        let second = try lease.claim(matching: "b", using: exact)
        #expect(second.record.identity.sequence == 1)
        #expect(try lease.consumeNext().identity.sequence == 0)
        let third = try lease.claim(matching: "a", using: exact)
        #expect(third.record.identity.sequence == 2)
        #expect(second.markConsumed())
        #expect(try lease.consumeNext().identity.sequence == 3)
        let result = await execution.finish()
        #expect(result.usage[0].tracks[0].activity == .replay(claimedCount: 4, unclaimedCount: 0))
        #expect(result.usage[0].tracks[0].claimedRecords.map(\.isConsumed) == [true, true, false, true])
        #expect(result.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(result.evaluate(.allClaimedRecordsConsumed).failures == [.unconsumedRecord(third.record.identity)])
    }

    @Test
    func `finish racing a selector rejects its stale result without consuming a record`() async throws {
        let (execution, lease) = try RecordCaptureFixtures.start(mode: .replay, values: ["a"])
        let entered = AsyncStream<Void>.makeStream()
        let completed = AsyncStream<Bool>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let selector = ReplaySelector<Void, String>(rule: DiagnosticLabel("slow")) { _, records in
            entered.continuation.finish()
            release.wait()
            return .equivalent(records.map(\.identity))
        }
        DispatchQueue.global().async {
            let rejected = (try? lease.claim(matching: (), using: selector)) == nil
            completed.continuation.yield(rejected)
            completed.continuation.finish()
        }
        for await _ in entered.stream {}
        let result = await execution.finish()
        release.signal()
        for await rejected in completed.stream {
            #expect(rejected)
        }
        #expect(result.usage[0].tracks[0].activity == .replay(claimedCount: 0, unclaimedCount: 1))
        #expect(lease.reporter.postFinishDiagnostics.last?.diagnostic.issue == .lifecycle(.leaseClosed))
        #expect(await execution.finish().usage == result.usage)
    }

    @Test
    func `safe differences run outside lease isolation and consumption closes progress`() async throws {
        let (execution, lease) = try RecordCaptureFixtures.start(mode: .replay, values: ["a"])
        let selector = ReplaySelector<String, String>.exactInput {
            $0
        } differences: { _, _ in
            #expect(!lease.isClosed)
            return [DiagnosticLabel("input")]
        }
        let claim = try lease.claim(matching: "a", using: selector)
        #expect(throws: SequentialOperationFailure.self) { try lease.claim(matching: "b", using: selector) }
        #expect(claim.markConsumed())
        #expect(!claim.advance(to: 2))
        #expect(await execution.finish().evaluate(.allClaimedRecordsConsumed).isSatisfied)
    }

    @Test(arguments: [Duration.milliseconds(200), .seconds(2)])
    func `current decisions preserve continuation delays for early and late answers`(answer: Duration) async throws {
        let captureClock = SchedulerTestClock()
        let (captureRun, captureServices) = try SchedulerFixtures.setup(clock: captureClock.source)
        let captureTime = captureServices[0].time
        captureClock.advance(to: .milliseconds(100))
        _ = try captureTime.capture() // Native challenge arrival.
        captureClock.advance(to: .milliseconds(600))
        let recordedAnswer = try captureTime.capture()
        captureClock.advance(to: .milliseconds(650))
        let response = try captureTime.capture()
        let delay = try captureTime.elapsed(from: recordedAnswer, to: response)
        #expect(delay == .milliseconds(50))
        _ = await captureRun.finish()

        let replayClock = SchedulerTestClock()
        let (replay, services) = try SchedulerFixtures.setup(clock: replayClock.source)
        let journal = SchedulerJournal()
        replayClock.advance(to: answer)
        let currentAnswer = try services[0].time.capture()
        let deadline = try services[0].time.logicalTime(after: delay, from: currentAnswer)
        try services[0].scheduling.schedule(at: deadline, for: SchedulerFixtures.record()) {
            journal.append("response")
        }
        #expect(try await replayClock.nextSleep().deadline == answer + .milliseconds(50))
        #expect(journal.values.isEmpty)
        replayClock.advance(to: deadline)
        #expect(await journal.take(1) == ["response"])
        #expect(await replay.finish().report.diagnostics.isEmpty)
    }
}
