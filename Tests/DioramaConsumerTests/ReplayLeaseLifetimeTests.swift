import DioramaCore
import Foundation
import Synchronization
import Testing

private struct ReplayLeaseDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.replay-lease")
    let values: SystemTrack<Int, Void>

    init(policy: ReplayContinuationPolicy<Int>, values: [Int] = []) throws {
        self.values = try SystemTrack("values", values: values.map { try ValuePreparation<Int>().admitPrepared($0) },
                                      continuationPolicy: policy)
    }

    var tracks: [AnySystemTrack] {
        [values.erased]
    }

    func makeRecordState(in context: borrowing SystemStateContext) throws -> HeaderlessSequentialTrackLease<Int> {
        try context.lease(for: values)
    }

    func makeReplayState(in context: borrowing SystemStateContext) throws -> HeaderlessSequentialTrackLease<Int> {
        try context.lease(for: values)
    }

    func makeRecordDependency(using runtime: SystemRuntime<HeaderlessSequentialTrackLease<Int>>)
        throws -> HeaderlessSequentialTrackLease<Int>
    {
        try runtime.withActiveState { values, _ in values }
    }

    func makeReplayDependency(using runtime: SystemRuntime<HeaderlessSequentialTrackLease<Int>>)
        throws -> HeaderlessSequentialTrackLease<Int>
    {
        try runtime.withActiveState { values, _ in values }
    }

    func makePassthroughDependency() throws -> HeaderlessSequentialTrackLease<Int> {
        throw CancellationError()
    }
}

struct ReplayLeaseLifetimeTests {
    @Test func `public replay lease preserves policy after managed state closes`() async throws {
        for policy in [ReplayContinuationPolicy<Int>.replayLast(defaultValue: -1), .fallback(-1), .error] {
            let definition = try ReplayLeaseDefinition(policy: policy, values: [9, 4])
            let system = try ScenarioSystem(named: "values", definition: definition)
            let execution = try start(system)
            let lease = try execution.dependency(system)
            #expect(try lease.consumeNext() == 9)
            let final = await execution.finish()
            switch policy {
            case .error:
                #expect(throws: SequentialOperationFailure.self) { try lease.consumeNext() }
            case .fallback:
                #expect(try lease.consumeNext() == -1)
            case .replayLast:
                #expect(try lease.consumeNext() == 9)
            }
            #expect(final.usage[0].tracks[0].unclaimedRecords.count == 1)
            #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
            #expect(await execution.finish().report == final.report)
        }
    }

    @Test func `finish joins an admitted direct replay read and its sink`() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let finished = Mutex(false)
        let system = try ScenarioSystem(named: "values", definition: ReplayLeaseDefinition(policy: .fallback(-1)))
        let execution = try start(system, sink: DiagnosticSink { entry in
            guard case .sequential(.replayExhausted) = entry.diagnostic.issue else { return }
            entered.continuation.finish()
            #expect(release.wait(timeout: .now() + 5) == .success)
        })
        let lease = try execution.dependency(system)
        let reading = Task { try lease.consumeNext() }
        for await _ in entered.stream {}
        let finishing = Task {
            let result = await execution.finish()
            finished.withLock { $0 = true }
            return result
        }
        for _ in 0..<10000 {
            if lease.isClosed {
                break
            }
            await Task.yield()
        }
        #expect(lease.isClosed)
        #expect(!finished.withLock { $0 })
        release.signal()
        #expect(try await reading.value == -1)
        let result = await finishing.value
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.sequential(.replayExhausted(availableCount: 0))])
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
    }

    private func start(_ system: ScenarioSystem<HeaderlessSequentialTrackLease<Int>>, sink: DiagnosticSink? = nil)
        throws -> ScenarioExecution
    {
        try ScenarioExecution.start(definition: ScenarioDefinition(attachments: [system.attachment]),
                                    scenarioID: .init(rawValue: "replay-lease"), defaultMode: .replay,
                                    systems: [AnyScenarioSystem(system)], sink: sink)
    }
}
