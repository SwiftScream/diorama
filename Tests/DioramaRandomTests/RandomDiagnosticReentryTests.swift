import DioramaCore
import DioramaRandom
import Foundation
import Synchronization
import Testing

struct RandomDiagnosticReentryTests {
    @Test func `reserved native read survives closure and finish joins unlocked reentrant notification`() async throws {
        let probe = RandomReentryProbe()
        // A failure releases both gates instead of stranding the runner.
        let timeout = DispatchWorkItem { probe.releaseSource.signal(); probe.releaseSink.signal() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel(); probe.releaseSource.signal(); probe.releaseSink.signal() }
        let system = try DioramaRandomSystem.instance(named: "reentry") { ReservedRandom(probe: probe) }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]), scenarioID: .init(rawValue: "reentry"),
            defaultMode: .record, systems: [AnyScenarioSystem(system)], sink: probe.sink)
        let generator = try execution.dependency(system)
        probe.callback.withLock { $0 = {
            var copy = generator
            #expect(copy.next() == 0)
            probe.reentries.withLock { $0 += 1 }
        } }
        let reading = Task { var copy = generator; return copy.next() }
        for await _ in probe.sourceEntered.stream {}
        let finishing = Task {
            let result = await execution.finish()
            probe.finished.withLock { $0 = true }
            return result
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        var closed = false
        while ContinuousClock.now < deadline {
            if (try? execution.dependency(system)) == nil {
                closed = true; break
            }
            await Task.yield()
        }
        #expect(closed)
        #expect(!probe.finished.withLock { $0 })
        probe.releaseSource.signal()
        for await _ in probe.sinkEntered.stream {}
        #expect(!probe.finished.withLock { $0 })
        let canceledWaiter = Task { await execution.finish() }
        canceledWaiter.cancel()
        probe.releaseSink.signal()
        #expect(await reading.value == 42)
        let final = await finishing.value
        #expect(await canceledWaiter.value.report == final.report)
        #expect(final.report.diagnostics.filter { $0.diagnostic.issue == .lifecycle(.leaseClosed) }.count == 2)
        #expect(final.report.diagnostics.contains { $0.diagnostic.issue == .verification(.recordingNotAdmitted) })
        #expect(final.definition == nil)
        #expect(probe.reentries.withLock { $0 } == 1)
        #expect(probe.reads.withLock { $0 } == 1)
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
    }
}

private final class RandomReentryProbe: Sendable {
    let sourceEntered = AsyncStream<Void>.makeStream()
    let sinkEntered = AsyncStream<Void>.makeStream()
    let releaseSource = DispatchSemaphore(value: 0)
    let releaseSink = DispatchSemaphore(value: 0)
    let finished = Mutex(false)
    let reentries = Mutex(0)
    let reads = Mutex(0)
    let callback = Mutex<(@Sendable () -> Void)?>(nil)

    var sink: DiagnosticSink {
        DiagnosticSink { entry in
            guard entry.diagnostic.context.recordIdentity != nil,
                  entry.diagnostic.issue == .lifecycle(.leaseClosed) else { return }
            let reenter = self.callback.withLock { stored in
                let detached = stored
                stored = nil
                return detached
            }
            reenter?()
            self.sinkEntered.continuation.yield(())
            self.sinkEntered.continuation.finish()
            self.releaseSink.wait()
        }
    }
}

private struct ReservedRandom: RandomNumberGenerator, Sendable {
    let probe: RandomReentryProbe

    func next() -> UInt64 {
        probe.reads.withLock { $0 += 1 }
        probe.sourceEntered.continuation.yield(())
        probe.sourceEntered.continuation.finish()
        probe.releaseSource.wait()
        return 42
    }
}
