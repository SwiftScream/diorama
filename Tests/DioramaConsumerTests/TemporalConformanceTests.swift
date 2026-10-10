import DioramaConsumerTestSupport
import DioramaCore
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TemporalConformanceTests {
    @Test
    func `public logical delay API diagnoses oversized Duration without trapping`() async throws {
        let system = try ConsumerTimedSystem.instance(key: "duration-bounds")
        let execution = try start(system, mode: .record)
        let time = try execution.dependency(system).time
        let anchor = try time.capture()
        let base = try time.logicalTime(at: anchor)
        #expect(try time.logicalTime(after: .zero, from: anchor) == base)
        #expect(try time.logicalTime(after: .milliseconds(125), from: anchor) == base + .milliseconds(125))
        let outside = Duration.seconds(Int64.max) * 2
        for delay in [outside, .seconds(Int64.max) + .seconds(1)] {
            do {
                _ = try time.logicalTime(after: delay, from: anchor)
                Issue.record("An oversized delay must fail safely")
            } catch {
                #expect(error.diagnostic.issue == .logicalTime(.overflow))
            }
        }
        do {
            _ = try time.logicalTime(after: .zero - outside, from: anchor)
            Issue.record("A negative delay must retain its existing failure")
        } catch {
            #expect(error.diagnostic.issue == .logicalTime(.negativeDelay))
        }
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .logicalTime(.overflow), .logicalTime(.overflow), .logicalTime(.negativeDelay),
        ])
    }

    @Test
    func `live capture preserves native order while replay runs and conversion is suspended`() async throws {
        let setup = try mixedSetup()
        let execution = setup.execution
        let capture = setup.capture
        let playback = setup.playback
        let beforeStart = try capture.time.logicalNow()
        let draft = try capture.begin(input: "updates")
        let afterStart = try capture.time.logicalNow()
        let beforeFirst = try capture.time.logicalNow()
        let first = try draft.observe()
        let afterFirst = try capture.time.logicalNow()
        let conversion = Gate()
        defer { conversion.release() }
        let slow = Task {
            await conversion.suspend()
            let firstEvent = try prepared(.batch([1, 2]), reporter: execution.reporter)
            return draft.complete(first, with: firstEvent)
        }
        await conversion.waitForEntry()
        try await replayResponse(playback)
        let beforeSecond = try capture.time.logicalNow()
        let second = try draft.observe()
        let afterSecond = try capture.time.logicalNow()
        let secondEvent = try prepared(.nonterminalFailure(9), reporter: execution.reporter)
        #expect(draft.complete(second, with: secondEvent))
        conversion.release()
        #expect(try await slow.value)
        #expect(!draft.complete(first, with: secondEvent))
        let result = await execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(draft.freezeCount == 1)
        #expect(!draft.complete(second, with: secondEvent))
        let recorded = try #require(try result.definition?.attachment(for: capture.records.id.attachmentID.key)?
            .track(capture.records.id, as: ConsumerTimedRecord.self))
        let observations = try #require(recorded.records.first?.value.observations)
        #expect(observations.map(\.event) == [.batch([1, 2]), .nonterminalFailure(9)])
        #expect(observations[0].delay >= beforeFirst - afterStart)
        #expect(observations[0].delay <= afterFirst - beforeStart)
        #expect(observations[1].delay >= beforeSecond - afterFirst)
        #expect(observations[1].delay <= afterSecond - beforeFirst)
        #expect(observations[1].delay >= .milliseconds(25))
        let preserved = try #require(try result.definition?.attachment(for: playback.records.id.attachmentID.key)?
            .track(playback.records.id, as: ConsumerTimedRecord.self))
        #expect(preserved.records.map(\.value) == [responseRecord()])
        #expect(result.usage[2].tracks[0].activity == .passthrough)
    }

    @Test
    func `captured batches and nonterminal failures replay to their open horizon`() async throws {
        let system = try ConsumerTimedSystem.instance(key: "round-trip")
        let recording = try start(system, mode: .record)
        let capture = try recording.dependency(system)
        let draft = try capture.begin(input: "updates")
        let first = try draft.observe()
        #expect(try draft.complete(first, with: prepared(.batch([4, 5]), reporter: recording.reporter)))
        try await ContinuousClock().sleep(for: .milliseconds(10))
        let second = try draft.observe()
        #expect(try draft.complete(second, with: prepared(.nonterminalFailure(6), reporter: recording.reporter)))
        let definition = try #require(await recording.finish().definition)
        let replay = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "round-trip"), defaultMode: .replay,
            systems: [AnyScenarioSystem(system)])
        let services = try replay.dependency(system)
        let claim = try services.records.claim(matching: "updates", using: .exactInput(\.input))
        let values = try await replayOpenSession(services, claim: claim)
        #expect(values == [.batch([4, 5]), .nonterminalFailure(6)])
        let result = await replay.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(result.usage[0].tracks[0].claimedRecords.first?.progressCount == 2)
    }

    @Test
    func `an unfinished conversion invalidates capture without waiting for live work`() async throws {
        let system = try ConsumerTimedSystem.instance(key: "slow")
        let execution = try start(system, mode: .record)
        let services = try execution.dependency(system)
        let draft = try services.begin(input: "updates")
        let position = try draft.observe()
        let event = try prepared(.batch([3]), reporter: execution.reporter)
        let conversion = Gate()
        defer { conversion.release() }
        let slow = Task {
            await conversion.suspend()
            return draft.complete(position, with: event)
        }
        await conversion.waitForEntry()
        let result = await execution.finish()
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(result.definition == nil)
        #expect(draft.freezeCount == 1)
        conversion.release()
        #expect(await !slow.value)
        #expect(throws: ConsumerSystemFailure.closed) { try draft.observe() }
        #expect(await execution.finish().report == result.report)
    }

    @Test(arguments: [Duration.zero, .milliseconds(60)])
    func `response delay starts at the current decision rather than invocation`(
        applicationWait: Duration) async throws
    {
        let system = try ConsumerTimedSystem.instance(key: "decisions", values: [responseRecord()])
        let execution = try start(system)
        let services = try execution.dependency(system)
        let claim = try services.records.claim(matching: "decision", using: .exactInput(\.input))
        let invoked = try services.time.capture()
        try await ContinuousClock().sleep(for: applicationWait)
        let answered = try services.time.capture()
        #expect(try services.time.elapsed(from: invoked, to: answered) >= applicationWait)
        let deadline = try services.time.logicalTime(after: claim.record.value.observations[0].delay, from: answered)
        let delivery = AsyncStream<Duration>.makeStream()
        try services.scheduling.schedule(at: deadline, for: claim.record.identity) {
            do {
                let arrived = try services.time.capture()
                #expect(claim.advance(to: 1))
                #expect(claim.markConsumed())
                try delivery.continuation.yield(services.time.elapsed(from: answered, to: arrived))
            } catch { Issue.record(error) }
            delivery.continuation.finish()
        }
        var iterator = delivery.stream.makeAsyncIterator()
        let elapsed = try #require(await iterator.next())
        #expect(elapsed >= .milliseconds(25))
        #expect(elapsed < .seconds(3))
        #expect(await execution.finish().evaluate(.allClaimedRecordsConsumed).isSatisfied)
    }

    @Test
    func `equal deadlines deliver open records through adapter selected actors exactly once`() async throws {
        let first = try ConsumerTimedSystem.instance(key: "first", values: [responseRecord()])
        let second = try ConsumerTimedSystem.instance(key: "second", values: [responseRecord()])
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [first.attachment, second.attachment]),
            scenarioID: ScenarioID(rawValue: "actors"), defaultMode: .replay,
            systems: [AnyScenarioSystem(second), AnyScenarioSystem(first)])
        let firstServices = try execution.dependency(first)
        let secondServices = try execution.dependency(second)
        let actor = Receiver()
        let mainActor = MainReceiver()
        let signals = AsyncStream<Void>.makeStream()
        let deadline = try firstServices.time.logicalNow() + .milliseconds(25)
        for (index, services) in [firstServices, secondServices].enumerated() {
            let claim = try services.records.claim(matching: "decision", using: .exactInput(\.input))
            try services.scheduling.schedule(at: deadline, for: claim.record.identity) {
                if index == 0 {
                    await actor.receive(index)
                } else {
                    await mainActor.receive(index)
                }
                #expect(claim.advance(to: 1))
                #expect(claim.markConsumed())
                signals.continuation.yield(())
            }
        }
        var iterator = signals.stream.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        let result = await execution.finish()
        #expect(await actor.values == [0])
        #expect(await mainActor.values == [1])
        #expect(result.usage.flatMap(\.tracks).flatMap(\.claimedRecords).map(\.progressCount) == [1, 1])
        #expect(result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test
    func `the adapter establishes causal delivery order through a suspended actor`() async throws {
        let record = ConsumerTimedRecord(input: "updates", observations: [
            ConsumerTimedObservation(delay: .zero, event: .batch([1])),
            ConsumerTimedObservation(delay: .zero, event: .nonterminalFailure(2)),
        ])
        let system = try ConsumerTimedSystem.instance(key: "ordered", values: [record])
        let execution = try start(system)
        let services = try execution.dependency(system)
        let claim = try services.records.claim(matching: (), using: .sequential())
        let receiver = Receiver()
        let gate = Gate()
        defer { gate.release() }
        let delivered = AsyncStream<Void>.makeStream()
        try services.scheduling.schedule(after: .zero, for: claim.record.identity) {
            await gate.suspend()
            // One awaited domain traversal establishes order across actor hops.
            for index in claim.record.value.observations.indices {
                await receiver.receive(index)
                #expect(claim.advance(to: UInt64(index + 1)))
            }
            #expect(claim.markConsumed())
            delivered.continuation.finish()
        }
        await gate.waitForEntry()
        #expect(await receiver.values.isEmpty)
        gate.release()
        for await _ in delivered.stream {}
        #expect(await execution.finish().evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(await receiver.values == [0, 1])
    }

    @Test
    func `finishing one execution leaves another execution and its claims active`() async throws {
        let system = try ConsumerTimedSystem.instance(key: "independent", values: [responseRecord()])
        let first = try start(system)
        let second = try start(system)
        let firstServices = try first.dependency(system)
        let secondServices = try second.dependency(system)
        #expect(firstServices.time !== secondServices.time)
        let foreign = try firstServices.time.capture()
        let firstClaim = try firstServices.records.claim(matching: (), using: .sequential())
        let secondClaim = try secondServices.records.claim(matching: (), using: .sequential())
        #expect(firstClaim.record.identity == secondClaim.record.identity)
        let firstPending = try firstServices.scheduling.schedule(after: .seconds(60), for: firstClaim.record.identity) {
            Issue.record("The finished execution must cancel pending work")
        }
        let firstResult = await first.finish()
        #expect(!firstPending.cancel())
        #expect(!firstClaim.markConsumed())
        #expect(!firstResult.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(!secondServices.records.isClosed)
        #expect(throws: ExecutionTimeFailure.self) { try secondServices.time.logicalTime(at: foreign) }
        let delivered = AsyncStream<Void>.makeStream()
        try secondServices.scheduling.schedule(after: .zero, for: secondClaim.record.identity) {
            #expect(secondClaim.markConsumed())
            delivered.continuation.finish()
        }
        for await _ in delivered.stream {}
        #expect(await second.finish().evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(await first.finish().usage == firstResult.usage)
    }

    @Test
    func `repeated teardown releases callback captures and rejects escaped scheduling`() async throws {
        let system = try ConsumerTimedSystem.instance(key: "teardown", values: [responseRecord()])
        for _ in 0..<16 {
            let execution = try start(system)
            let services = try execution.dependency(system)
            let claim = try services.records.claim(matching: (), using: .sequential())
            let pending = try pendingReceiver(services, record: claim.record.identity)
            #expect(pending.receiver != nil)
            let result = await execution.finish()
            #expect(!pending.handle.cancel())
            #expect(pending.receiver == nil)
            #expect(!claim.markConsumed())
            #expect(throws: SchedulingFailure.self) {
                try services.scheduling.schedule(after: .zero, for: claim.record.identity) {
                    Issue.record("Escaped scheduling must not deliver")
                }
            }
            #expect(result.report.diagnostics.isEmpty)
            #expect(execution.reporter.postFinishDiagnostics.count == 1)
            #expect(await execution.finish().report == result.report)
        }
    }
}

extension TemporalConformanceTests {
    private func replayOpenSession(_ services: ConsumerTimedServices, claim: ReplayClaim<ConsumerTimedRecord>)
        async throws -> [ConsumerTimedEvent]
    {
        let anchor = try services.time.capture()
        var offset = Duration.zero
        var values: [ConsumerTimedEvent] = []
        for (index, observation) in claim.record.value.observations.enumerated() {
            offset += observation.delay
            let deadline = try services.time.logicalTime(after: offset, from: anchor)
            let delivery = AsyncStream<ConsumerTimedEvent>.makeStream()
            try services.scheduling.schedule(at: deadline, for: claim.record.identity) {
                do {
                    #expect(try services.time.logicalNow() >= deadline)
                } catch { Issue.record(error) }
                #expect(claim.advance(to: UInt64(index + 1)))
                delivery.continuation.yield(observation.event)
                delivery.continuation.finish()
            }
            var iterator = delivery.stream.makeAsyncIterator()
            try values.append(#require(await iterator.next()))
        }
        // The open horizon has been reached; no terminal event is synthesized.
        #expect(claim.markConsumed())
        return values
    }

    private struct MixedSetup {
        let execution: ScenarioExecution
        let capture: ConsumerTimedServices
        let playback: ConsumerTimedServices
    }

    private func mixedSetup() throws -> MixedSetup {
        let live = try ConsumerTimedSystem.instance(key: "live").withMode(.record)
        let replay = try ConsumerTimedSystem.instance(key: "replay", values: [responseRecord()])
        let passthrough = try ConsumerSequentialSystem.instance(key: AttachmentKey(rawValue: "passthrough"))
            .withMode(.passthrough)
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [live.attachment, replay.attachment, passthrough.attachment]),
            scenarioID: ScenarioID(rawValue: "mixed-time"), defaultMode: .replay,
            systems: [AnyScenarioSystem(passthrough), AnyScenarioSystem(replay), AnyScenarioSystem(live)])
        let capture = try execution.dependency(live)
        let playback = try execution.dependency(replay)
        let passive = try execution.dependency(passthrough)
        #expect(capture.time === playback.time)
        #expect(capture.records.mode == .record)
        #expect(playback.records.mode == .replay)
        #expect(passive.mode == .passthrough)
        #expect(try passive.next(capturing: { ConsumerStableValue(7) }).number == 7)
        return MixedSetup(execution: execution, capture: capture, playback: playback)
    }

    private func replayResponse(_ playback: ConsumerTimedServices) async throws {
        let claim = try playback.records.claim(matching: "decision", using: .exactInput(\.input))
        let decision = try playback.time.capture()
        let deadline = try playback.time.logicalTime(after: claim.record.value.observations[0].delay, from: decision)
        let delivered = AsyncStream<Duration>.makeStream()
        let handle = try playback.scheduling.schedule(at: deadline, for: claim.record.identity) {
            do {
                try delivered.continuation.yield(playback.time.logicalNow())
                #expect(claim.advance(to: 1))
                #expect(claim.markConsumed())
            } catch { Issue.record(error) }
            delivered.continuation.finish()
        }
        var iterator = delivered.stream.makeAsyncIterator()
        let actual = try #require(await iterator.next())
        #expect(actual >= deadline)
        #expect(actual - deadline < .seconds(3))
        #expect(!handle.cancel())
    }

    private struct CallbackCapture {
        let handle: ScheduledItemHandle
        weak var receiver: Receiver?
    }

    private func pendingReceiver(_ services: ConsumerTimedServices, record: RecordIdentity) throws -> CallbackCapture {
        let receiver = Receiver()
        let handle = try services.scheduling.schedule(after: .seconds(60), for: record) {
            await receiver.receive(0)
            Issue.record("Pending delivery must not escape finish")
        }
        return CallbackCapture(handle: handle, receiver: receiver)
    }

    private func responseRecord() -> ConsumerTimedRecord {
        ConsumerTimedRecord(input: "decision", observations: [
            ConsumerTimedObservation(delay: .milliseconds(25), event: .response(200)),
        ])
    }

    private func start(_ system: ScenarioSystem<ConsumerTimedServices>, mode: ScenarioMode = .replay) throws
        -> ScenarioExecution
    {
        try ScenarioExecution.start(definition: ScenarioDefinition(attachments: [system.attachment]),
                                    scenarioID: ScenarioID(rawValue: "timed-consumer"), defaultMode: mode,
                                    systems: [AnyScenarioSystem(system)])
    }

    private func prepared(_ event: ConsumerTimedEvent, reporter: DiagnosticReporter) throws
        -> PreparedValue<ConsumerTimedEvent>
    {
        try ValuePreparation<ConsumerTimedEvent>().prepare(
            capturing: { event }, purpose: .recording, reporter: reporter)
    }

    private actor Receiver {
        var values: [Int] = []
        func receive(_ value: Int) {
            preconditionIsolated()
            values.append(value)
        }
    }

    @MainActor
    private final class MainReceiver {
        var values: [Int] = []
        func receive(_ value: Int) {
            MainActor.preconditionIsolated()
            values.append(value)
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
