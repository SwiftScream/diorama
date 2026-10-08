import Diorama
import DioramaConsumerTestSupport
import DioramaCore
import DioramaDate
import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DateSchedulingConformanceTests {
    @Test(arguments: [false, true])
    func `application timeout composes with timed batches and responses independently of wall adjustments`(
        timesOut: Bool) async throws
    {
        let record = ConsumerTimedRecord(input: "request", observations: [
            ConsumerTimedObservation(delay: .zero, event: .batch([1, 2])),
            ConsumerTimedObservation(delay: timesOut ? .seconds(60) : .milliseconds(10), event: .response(200)),
        ])
        let timed = try ConsumerTimedSystem.instance(key: "interaction", values: [record])
        let baseline = try ScenarioDefinition(attachments: [timed.attachment])
        let source = DateConformanceSupport.Source([1000, -1000])
        let wall = try DioramaDateSystem.instance(named: "wall") { source }.withMode(.passthrough)
        let result = try await Diorama(definition: baseline, scenarioID: "timeout", mode: .replay, systems: timed, wall)
            .execute { context, services, wall in
                let claim = try services.records.claim(matching: "request", using: .exactInput(\.input))
                let stream = AsyncStream<ConsumerTimedEvent>.makeStream()
                let start = context.clock.now
                #expect(wall.now == Date(timeIntervalSince1970: 1000))
                let delivery = try traverse(services, claim: claim, start: start, stream: stream.continuation)
                defer {
                    _ = delivery.cancel()
                    stream.continuation.finish()
                }
                let response = try await withThrowingTaskGroup(of: Int?.self) { group in
                    group.addTask {
                        var events: [ConsumerTimedEvent] = []
                        for await event in stream.stream {
                            events.append(event)
                            if case let .response(code) = event {
                                #expect(events == [.batch([1, 2]), .response(200)])
                                return code
                            }
                        }
                        return nil
                    }
                    group.addTask {
                        let deadline = start.advanced(by: timesOut ? .milliseconds(20) : .seconds(5))
                        try await context.clock.sleep(until: deadline)
                        return nil
                    }
                    let first = try await group.next()
                    group.cancelAll()
                    return first ?? nil
                }
                #expect(wall.now == Date(timeIntervalSince1970: -1000))
                #expect(context.clock.now > start)
                return response
            }
        #expect(result.body == (timesOut ? nil : 200))
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.finalization.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(result.finalization.evaluate(.allClaimedRecordsConsumed).isSatisfied == !timesOut)
        #expect(source.count == 2)
    }

    @MainActor
    @Test(arguments: [ScenarioMode.record, .replay, .passthrough])
    func `finish joins claimed domain delivery cancels clock sleeps and closes independent wall handles`(
        mode: ScenarioMode) async throws
    {
        let bytes = try DateConformanceSupport.fixture()
        let definition = try DateConformanceSupport.codec().decode(bytes)
        let wallSource = DateConformanceSupport.Source([123])
        let wallSystem = try DioramaDateSystem.instance(named: "empty") { wallSource }
        let timed = try ConsumerTimedSystem.instance(key: "pending", values: [
            ConsumerTimedRecord(input: "request", observations: []),
        ]).withMode(.replay)
        let empty = try #require(definition.attachment(for: AttachmentKey(rawValue: "empty")))
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [empty, timed.attachment]),
            scenarioID: ScenarioID(rawValue: "quiescence"), defaultMode: mode,
            systems: [AnyScenarioSystem(wallSystem), AnyScenarioSystem(timed)])
        let wall = try execution.dependency(wallSystem)
        let services = try execution.dependency(timed)
        let claim = try services.records.claim(matching: (), using: .sequential())
        let gate = Gate()
        defer { gate.release() }
        let entered = AsyncStream<Void>.makeStream()
        // Both tasks inherit MainActor. The reader resumes only after this
        // task enters the clock's suspension, so finish sees an admitted sleep.
        let pendingSleep = Task {
            entered.continuation.finish()
            try await execution.context.clock.sleep(for: .seconds(60))
        }
        for await _ in entered.stream {}
        let deliveries = Mutex(0)
        try services.scheduling.schedule(after: .zero, for: claim.record.identity) {
            await gate.suspend()
            deliveries.withLock { $0 += 1 }
            // Claimed deliveries can acknowledge consumption before report freezing.
            #expect(claim.markConsumed())
        }
        await gate.waitForEntry()
        let finished = Mutex(false)
        let finishing = Task {
            let result = await execution.finish()
            finished.withLock { $0 = true }
            return result
        }
        // A clock sleep can only be canceled once shutdown has begun.
        await #expect(throws: CancellationError.self) { try await pendingSleep.value }
        #expect(!finished.withLock { $0 })
        #expect(deliveries.withLock { $0 } == 0)
        gate.release()
        let result = await finishing.value
        #expect(deliveries.withLock { $0 } == 1)
        #expect(result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(result.report.diagnostics.isEmpty)
        #expect(wall.now == Date(timeIntervalSince1970: 0))
        #expect(wallSource.count == 0)
        let horizon = execution.context.clock.now
        #expect(services.clock.now == horizon)
        #expect(await execution.finish().report == result.report)
        #expect(execution.reporter.postFinishDiagnostics.count == 3)
    }

    private func traverse(
        _ services: ConsumerTimedServices, claim: ReplayClaim<ConsumerTimedRecord>,
        start: ScenarioClock.Instant, stream: AsyncStream<ConsumerTimedEvent>.Continuation) throws
        -> ScheduledItemHandle
    {
        try services.scheduling.schedule(at: start.offset, for: claim.record.identity) {
            // One owned traversal establishes causal order across suspensions.
            for (index, observation) in claim.record.value.observations.enumerated() {
                do {
                    try await services.clock.sleep(for: observation.delay)
                } catch is CancellationError {
                    stream.finish()
                    return
                } catch {
                    Issue.record(error)
                    stream.finish()
                    return
                }
                #expect(claim.advance(to: UInt64(index + 1)))
                if index == claim.record.value.observations.count - 1 {
                    #expect(claim.markConsumed())
                }
                stream.yield(observation.event)
            }
            stream.finish()
        }
    }

    private final class Gate: Sendable {
        private let entry = AsyncStream<Void>.makeStream()
        private let released = AsyncStream<Void>.makeStream()

        func suspend() async {
            entry.continuation.finish()
            for await _ in released.stream {}
        }

        func waitForEntry() async {
            for await _ in entry.stream {}
        }

        func release() {
            released.continuation.finish()
        }
    }
}
