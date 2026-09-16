import DioramaCore
import Dispatch
import Synchronization
import Testing

/// Each case may hold one synchronous cleanup callback. Keep the cases serial
/// so the two-CPU Linux gate retains a worker to drive their explicit races.
@Suite(.serialized)
struct ConcurrentFinalizationTests {
    @Test(arguments: [false, true])
    func `canceled callers share overlapping cleanup`(alreadyCanceled: Bool) async throws {
        let gate = FinalizationGate()
        defer { gate.release() }
        let journal = ExecutionFixtures.Journal()
        let second = blockingSystem(gate: gate, journal: journal)
        let execution = try ScenarioExecution.start(definition: ExecutionFixtures.definition(["a", "b"]), systems: [
            ExecutionFixtures.system("a", journal: journal), second,
        ])
        let lease = try execution.dependency(
            ExecutionFixtures.dependencyKey("a", as: SequentialTrackLease<Int>.self))
        #expect(try lease.claimNext().value == 1)
        let returned = Mutex(0)
        let first = Task {
            if alreadyCanceled {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            let result = await execution.finish()
            returned.withLock { $0 += 1 }
            return result
        }
        await gate.waitForEntry()
        first.cancel()
        let started = AsyncStream<Void>.makeStream()
        let others = (0..<6).map { _ in
            Task {
                started.continuation.yield(())
                return await execution.finish()
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        for _ in others {
            _ = await iterator.next()
        }
        others[0].cancel()
        #expect(returned.withLock { $0 } == 0)
        #expect(lease.isClosed)
        #expect(throws: SequentialOperationFailure.self) { try lease.claimNext() }
        gate.release()
        let result = await first.value
        for other in others {
            #expect(await other.value == result)
        }
        #expect(await execution.finish() == result)
        #expect(result.cleanup.map(\.disposition) == [.completed, .failed])
        #expect(journal.events.withLock { $0.filter { $0.hasPrefix("cleanup-") } } == ["cleanup-b", "cleanup-a"])
        #expect(result.usage[0].tracks[0].activity == .replay(usedCount: 1, unusedCount: 1))
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.leaseClosed), .lifecycle(.cleanupFailed),
        ])
        #expect(!result.evaluate(.successfulCleanup).isSatisfied)
        #expect(journal.descriptions.withLock { $0 } == 0)
    }

    @Test(arguments: [false, true])
    func `diagnostics racing finish partition exactly once into frozen and late logs`(hasSink: Bool) async throws {
        let notifications = Mutex<[ReportedDiagnostic]>([])
        let reference = Mutex<DiagnosticReporter?>(nil)
        defer { reference.withLock { $0 = nil } }
        let sink = DiagnosticSink { entry in
            let reporter = try #require(reference.withLock { $0 })
            #expect(reporter.report.diagnostics.contains(entry) || reporter.postFinishDiagnostics.contains(entry))
            notifications.withLock { $0.append(entry) }
        }
        let execution = try ScenarioExecution.start(definition: ExecutionFixtures.definition(["a"]), systems: [
            ExecutionFixtures.system("a", journal: ExecutionFixtures.Journal()),
        ], sink: hasSink ? sink : nil)
        let reporter = execution.reporter
        reference.withLock { $0 = reporter }
        reporter.record(Diagnostic(issue: .system(DiagnosticLabel("before"))))
        let barrier = FinalizationBarrier(participants: 129)
        let result = await withTaskGroup(of: Void.self) { group in
            for sequence in 0..<128 {
                group.addTask {
                    await barrier.arrive()
                    reporter.record(Diagnostic(issue: .system(DiagnosticLabel("racing")),
                                               context: .record(RecordIdentity(trackID: ExecutionFixtures.track("a"),
                                                                               sequence: UInt64(sequence))),
                                               recordingImpact: .invalidatesCandidate))
                }
            }
            await barrier.arrive()
            return await execution.finish()
        }
        reporter.record(Diagnostic(issue: .system(DiagnosticLabel("after")), recordingImpact: .invalidatesCandidate))
        let all = result.report.diagnostics + reporter.postFinishDiagnostics
        #expect(all.count == 130)
        #expect(all.map(\.sequence).sorted() == Array(0..<UInt64(130)))
        #expect(all.compactMap(\.diagnostic.context.recordIdentity?.sequence).sorted() == Array(0..<UInt64(128)))
        #expect(result.report.recordingHealth.failures.count == result.report.diagnostics.count - 1)
        #expect(notifications.withLock { $0.sorted { $0.sequence < $1.sequence } } ==
            (hasSink ? all.sorted { $0.sequence < $1.sequence } : []))
        #expect(await execution.finish() == result)
        #expect(reporter.report == result.report)
    }

    @Test
    func `finish reports a reserved observation while late preparation cannot mutate the result`() async throws {
        let gate = FinalizationGate()
        defer { gate.release() }
        let execution = try ScenarioExecution.start(
            definition: ExecutionFixtures.definition(["a"], mode: .record), systems: [
                ExecutionFixtures.system("a", journal: ExecutionFixtures.Journal()),
            ])
        let lease = try execution.dependency(
            ExecutionFixtures.dependencyKey("a", as: SequentialTrackLease<Int>.self))
        let operation = Task<SequentialOperationFailure?, Never> {
            await withCheckedContinuation { continuation in
                // A deliberately blocked capture must not occupy a cooperative worker.
                DispatchQueue.global().async {
                    let failure: SequentialOperationFailure?
                    do {
                        try lease.append(capturing: { gate.enter(); return 7 }, preparation: ValuePreparation<Int>())
                        failure = nil
                    } catch { failure = error as? SequentialOperationFailure }
                    continuation.resume(returning: failure)
                }
            }
        }
        await gate.waitForEntry()
        let result = await execution.finish()
        #expect(result.usage[0].tracks[0].activity == .record(recordedCount: 0, incompleteCount: 1))
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.verification(.recordingNotAdmitted)])
        #expect(!result.report.recordingHealth.isHealthy)
        gate.release()
        #expect(await operation.value?.diagnostic.issue == .lifecycle(.leaseClosed))
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
        #expect(await execution.finish() == result)
    }

    private func blockingSystem(gate: FinalizationGate, journal: ExecutionFixtures.Journal) -> AnyScenarioSystem {
        let system = ScenarioSystem(attachment: ScenarioAttachment(id: ExecutionFixtures.attachment("b"))) { context in
            let lease = try context.lease(for: ExecutionFixtures.track("b"), preparation: ValuePreparation<Int>())
            return PreparedSystem {
                ActivatedSystem(dependency: lease) {
                    #expect(!Task.isCancelled)
                    journal.events.withLock { $0.append("cleanup-b") }
                    gate.enter()
                    throw ExecutionFixtures.SecretError(journal: journal)
                }
            }
        }
        return AnyScenarioSystem(system)
    }
}

/// Blocks only the synchronous operation under test; the observer suspends.
private final class FinalizationGate: Sendable {
    private let entry = AsyncStream<Void>.makeStream()
    private let semaphore = DispatchSemaphore(value: 0)

    func enter() {
        entry.continuation.yield(())
        #expect(semaphore.wait(timeout: .now() + 10) == .success)
    }

    func waitForEntry() async {
        for await _ in entry.stream {
            return
        }
    }

    func release() {
        semaphore.signal()
    }
}

private actor FinalizationBarrier {
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
