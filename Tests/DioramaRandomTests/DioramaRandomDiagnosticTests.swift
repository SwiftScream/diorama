import DioramaCore
import DioramaRandom
import Dispatch
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DioramaRandomDiagnosticTests {
    @Test
    func `finish joins a reserved live read and retains its diagnostic facts`() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let finished = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let released = Mutex(0)
        let random = try DioramaRandomSystem.instance(named: "blocked") {
            GatedRecordingSource(entered: entered.continuation, release: release,
                                 onRelease: { released.withLock { $0 += 1 } })
        }
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [random.attachment]),
            scenarioID: ScenarioID(rawValue: "diagnostic-finish-race"), defaultMode: .record,
            systems: [AnyScenarioSystem(random)])
        let generator = try execution.dependency(random)
        let reading = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    var generator = generator
                    continuation.resume(returning: generator.next())
                }
            }
        }
        for await _ in entered.stream {}
        #expect(execution.reporter.report == nil)
        let finish = Task {
            let result = await execution.finish()
            finished.withLock { $0 = true }
            return result
        }
        await waitForClosure(execution, system: random)
        #expect(!finished.withLock { $0 })
        #expect(execution.reporter.report == nil)
        let canceledWaiter = Task { await execution.finish() }
        canceledWaiter.cancel()
        release.signal()
        #expect(await reading.value == 17)
        let result = await finish.value
        #expect(await canceledWaiter.value.report == result.report)
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.executionClosed), .lifecycle(.leaseClosed), .verification(.recordingNotAdmitted),
        ])
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(released.withLock { $0 } == 0)
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
        var retained = generator
        #expect(retained.next() == 18)
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
        #expect(await execution.finish().report == result.report)
        withExtendedLifetime(retained) {}
    }

    private func waitForClosure(
        _ execution: ScenarioExecution, system: ScenarioSystem<any RandomNumberGenerator & Sendable>) async
    {
        // Admission closes before managed operations drain. Cleanup waits for
        // the blocked read; rejected lookup contributes one executionClosed fact.
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            if (try? execution.dependency(system)) == nil {
                return
            }
            await Task.yield()
        }
        Issue.record("Finish did not close admission")
    }
}

private final class GatedRecordingSource: RandomNumberGenerator, Sendable {
    let reads = Mutex(0)
    let entered: AsyncStream<Void>.Continuation
    let release: DispatchSemaphore
    let onRelease: @Sendable () -> Void

    init(entered: AsyncStream<Void>.Continuation, release: DispatchSemaphore,
         onRelease: @escaping @Sendable () -> Void)
    {
        self.entered = entered
        self.release = release
        self.onRelease = onRelease
    }

    func next() -> UInt64 {
        let count = reads.withLock { $0 += 1; return $0 }
        if count == 1 {
            entered.finish()
            #expect(release.wait(timeout: .now() + 10) == .success)
        }
        return UInt64(16 + count)
    }

    deinit { onRelease() }
}
