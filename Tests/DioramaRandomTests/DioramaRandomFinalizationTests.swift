import DioramaCore
import DioramaRandom
import Synchronization
import Testing

struct DioramaRandomFinalizationTests {
    @Test
    func `racing random claims and finish account for every value exactly once`() async throws {
        let key = AttachmentKey(rawValue: "race")
        let values = Array(UInt64(1000)..<1128)
        let (execution, instance) = try replayExecution(key: key, values: values)
        let generator = try execution.dependency(instance)
        let start = RandomStartBarrier(participants: values.count + 1)
        let returns = Mutex<[UInt64]>([])
        let result = await withTaskGroup(of: Void.self) { group in
            for _ in values {
                group.addTask {
                    await start.arrive()
                    var generator = generator
                    let value = generator.next()
                    returns.withLock { $0.append(value) }
                }
            }
            await start.arrive()
            return await execution.finish()
        }
        let used = returns.withLock { $0.filter { $0 != 0 }.sorted() }
        #expect(used == Array(values.prefix(used.count)))
        #expect(result.usage[0].tracks[0].activity == .replay(
            usedCount: UInt64(used.count), unusedCount: UInt64(values.count - used.count)))
        let unused = result.usage[0].tracks[0].unusedRecords
        #expect(unused.map(\.sequence) == Array(UInt64(used.count)..<UInt64(values.count)))
        #expect(result.evaluate(.allRecordingsUsed).failures == unused.map { .unusedRecord($0) })
        let diagnostics = result.report.diagnostics + execution.reporter.postFinishDiagnostics
        #expect(diagnostics.count == values.count - used.count)
        #expect(diagnostics.allSatisfy { $0.diagnostic.issue == .lifecycle(.leaseClosed) })
        #expect(await execution.finish() == result)
    }

    @Test
    func `unused random identities remain reportable after the execution is released`() async throws {
        let key = AttachmentKey(rawValue: "escaped")
        var generator: any (RandomNumberGenerator & Sendable)?
        var reporter: DiagnosticReporter?
        weak var weakExecution: ScenarioExecution?
        weak var weakReporter: DiagnosticReporter?
        let result: ScenarioFinalizationResult
        do {
            let (execution, instance) = try replayExecution(key: key, values: [0, .max, 17])
            weakExecution = execution
            generator = try execution.dependency(instance)
            reporter = execution.reporter
            weakReporter = reporter
            #expect(generator?.next() == 0)
            result = await execution.finish()
        }
        #expect(weakExecution == nil)
        let text = result.rendered()
        #expect(result.usage[0].tracks[0].activity == .replay(usedCount: 1, unusedCount: 2))
        #expect(generator?.next() == 0)
        #expect(reporter?.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
        #expect(result.rendered() == text)
        #expect(result.evaluate(.noUnexpectedOperations).isSatisfied)
        reporter = nil
        #expect(weakReporter != nil)
        generator = nil
        #expect(weakReporter == nil)
        #expect(result.evaluate(.allRecordingsUsed).failures.count == 2)
    }

    private func replayExecution(
        key: AttachmentKey,
        values: [UInt64]) throws
        -> (ScenarioExecution, ScenarioSystem<any RandomNumberGenerator & Sendable>)
    {
        let preparation = ValuePreparation<UInt64>()
        let reporter = try DiagnosticReporter(
            scenarioID: ScenarioID(rawValue: "fixture"),
            definition: ScenarioDefinition())
        let prepared = try values.map { value in
            try preparation.prepare(capturing: { value }, purpose: .replay, reporter: reporter)
        }
        let attachment = try ScenarioAttachment(id: DioramaRandomSystem.attachmentID(for: key)).adding(
            SequentialTrack(id: DioramaRandomSystem.trackID(for: key), values: prepared))
        let instance = try DioramaRandomSystem.instance(for: key) { () -> SystemRandomNumberGenerator in
            fatalError("Replay finalization must remain offline")
        }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            configuration: ScenarioConfiguration(id: ScenarioID(rawValue: "random-finalization"), defaultMode: .replay),
            systems: [AnyScenarioSystem(instance)])
        return (execution, instance)
    }
}

private actor RandomStartBarrier {
    private var remaining: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participants: Int) {
        remaining = participants
    }

    func arrive() async {
        remaining -= 1
        if remaining == 0 {
            let ready = waiters
            waiters = []
            for waiter in ready {
                waiter.resume()
            }
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
