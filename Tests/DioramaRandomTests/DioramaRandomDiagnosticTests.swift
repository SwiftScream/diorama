import DioramaCore
import DioramaRandom
import Dispatch
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DioramaRandomDiagnosticTests {
    @Test
    func `reserved live read racing finish retains diagnostics without source lock reentry`() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let finishing = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let released = Mutex(0)
        let random = try DioramaRandomSystem.instance(named: "blocked") {
            GatedRecordingSource(entered: entered.continuation, release: release,
                                 onRelease: { released.withLock { $0 += 1 } })
        }
        let probe = try cleanupProbe(finishing.continuation)
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [random.attachment, probe.attachment]),
            scenarioID: ScenarioID(rawValue: "diagnostic-finish-race"), defaultMode: .record,
            systems: [AnyScenarioSystem(random), AnyScenarioSystem(probe)])
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
        let finish = Task { await execution.finish() }
        // Reverse cleanup begins only after the leases close. The source is
        // still blocked inside a reserved read when finish reaches this point.
        for await _ in finishing.stream {}
        #expect(execution.reporter.report == nil)
        release.signal()
        #expect(await reading.value == 17)
        let result = await finish.value
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .verification(.recordingNotAdmitted), .lifecycle(.leaseClosed),
        ])
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(released.withLock { $0 } == 1)
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
        #expect(await execution.finish().report == result.report)
    }

    private func cleanupProbe(_ entered: AsyncStream<Void>.Continuation) throws -> ScenarioSystem<Void> {
        let type = ScenarioSystemType("test.cleanup-probe")
        let id = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: "probe"))
        return try ScenarioSystem(type: type, attachment: ScenarioAttachment(id: id)) { _ in
            PreparedSystem { ActivatedSystem(dependency: (), deactivate: { entered.finish() }) }
        }
    }
}

private final class GatedRecordingSource: RandomNumberGenerator, Sendable {
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
        entered.finish()
        #expect(release.wait(timeout: .now() + 10) == .success)
        return 17
    }

    deinit { onRelease() }
}
