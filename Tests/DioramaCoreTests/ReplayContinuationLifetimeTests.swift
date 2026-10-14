@testable import DioramaCore
import Dispatch
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ReplayContinuationLifetimeTests {
    enum PolicyKind: CaseIterable, Sendable {
        case error
        case fallback
        case replayLast

        func policy(_ value: Probe) -> ReplayContinuationPolicy<Probe> {
            switch self {
            case .error: .error
            case .fallback: .fallback(value)
            case .replayLast: .replayLast(defaultValue: value)
            }
        }
    }

    final class Probe: Sendable {
        let value: Int
        let onRelease: @Sendable () -> Void

        init(_ value: Int, onRelease: @escaping @Sendable () -> Void = {}) {
            self.value = value
            self.onRelease = onRelease
        }

        deinit { onRelease() }
    }

    private struct Witnesses {
        weak var consumed: Probe?
        weak var unread: Probe?
        weak var initial: Probe?
    }

    @Test(arguments: PolicyKind.allCases)
    func `closed leases retain only the continuation selected by their policy`(_ kind: PolicyKind) throws {
        let (lease, witnesses) = try makeLease(kind: kind)
        #expect(witnesses.consumed != nil)
        #expect(witnesses.unread != nil)
        #expect(try lease.consumeNext().value == 1)
        #expect(witnesses.initial == nil || kind == .fallback)
        lease.close()
        #expect(witnesses.unread == nil)
        #expect((witnesses.initial != nil) == (kind == .fallback))
        #expect((witnesses.consumed != nil) == (kind == .replayLast))
        switch kind {
        case .error:
            #expect(throws: SequentialOperationFailure.self) { try lease.consumeNext() }
        case .fallback:
            #expect(try lease.consumeNext().value == -1)
        case .replayLast:
            #expect(try lease.consumeNext().value == 1)
        }
    }

    @Test
    func `replacing the initial continuation releases its value outside the lease lock`() throws {
        let reference = Mutex<SequentialTrackLease<Probe, Void>?>(nil)
        defer { reference.withLock { $0 = nil } }
        let observed = Mutex<[Int]>([])
        let lease: SequentialTrackLease<Probe, Void>
        do {
            let initial = Probe(-1) {
                guard let lease = reference.withLock({ $0 }) else { return }
                let next = try? lease.consumeNext()
                if let next {
                    observed.withLock { $0.append(next.value) }
                }
            }
            let track = try SequentialTrack(
                id: ExecutionFixtures.track("release"), values: preparedValues([Probe(1), Probe(2)]))
            lease = try SequentialTrackLease(
                track: track, baseline: track.records, baselineHeader: (), mode: .replay,
                reporter: DiagnosticReporter(
                    scenarioID: ScenarioID(rawValue: "release"), definition: ScenarioDefinition()),
                admission: ExecutionAdmission(),
                continuationPolicy: .replayLast(defaultValue: initial))
        }
        reference.withLock { $0 = lease }
        #expect(try lease.consumeNext().value == 1)
        #expect(observed.withLock { $0 } == [2])
        lease.close()
        #expect(try lease.consumeNext().value == 2)
    }

    @Test
    func `default destruction waits for enclosing managed state protection`() throws {
        let protected = Mutex(0)
        let actions = PostUnlockActions()
        let lease: HeaderlessSequentialTrackLease<Probe>
        do {
            let initial = Probe(-1) { protected.withLock { $0 += 1 } }
            let track = try SequentialTrack(id: ExecutionFixtures.track("managed-release"),
                                            values: preparedValues([Probe(1)]))
            lease = try SequentialTrackLease(
                track: track, baseline: track.records, baselineHeader: (), mode: .replay,
                reporter: DiagnosticReporter(
                    scenarioID: .init(rawValue: "managed-release"), definition: ScenarioDefinition()),
                admission: ExecutionAdmission(), continuationPolicy: .replayLast(defaultValue: initial))
        }
        try PostUnlockActions.$current.withValue(actions) {
            try protected.withLock { count in
                let value = try lease.consumeNext().value
                #expect(value == 1)
                #expect(count == 0)
            }
        }
        actions.drain()
        #expect(protected.withLock { $0 } == 1)
        lease.close()
    }

    @Test
    func `finish joins direct reads through continuation destruction and retained facts`() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let finished = Mutex(false)
        let id = ExecutionFixtures.track("joined-release")
        let track = try SequentialTrack(id: id, values: preparedValues([Probe(1)]))
        let attachment = try ScenarioAttachment(id: id.attachmentID).adding(track)
        let system = try ScenarioSystem(type: ScenarioSystemType(id.attachmentID.systemTypeID.rawValue),
                                        attachment: attachment)
        { context in
            let reporter = context.reporter
            let lease = try context.lease(for: id, preparation: ValuePreparation<Probe>(),
                                          continuationPolicy: .replayLast(defaultValue: Probe(-1) {
                                              entered.continuation.finish()
                                              #expect(release.wait(timeout: .now() + 10) == .success)
                                              reporter.record(Diagnostic(issue: .system(DiagnosticLabel("released"))))
                                          }))
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]), scenarioID: .init(rawValue: "joined-release"),
            defaultMode: .replay, systems: [AnyScenarioSystem(system)])
        let lease = try execution.dependency(system)
        let reading = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: try? lease.consumeNext().value)
                }
            }
        }
        for await _ in entered.stream {}
        let finishing = Task {
            let result = await execution.finish()
            finished.withLock { $0 = true }
            return result
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !lease.isClosed, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(lease.isClosed)
        #expect(!finished.withLock { $0 })
        #expect(execution.reporter.report == nil)
        release.signal()
        #expect(await reading.value == 1)
        let final = await finishing.value
        #expect(final.report.diagnostics.map(\.diagnostic.issue) == [.system(DiagnosticLabel("released"))])
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
    }

    @Test(arguments: [ScenarioMode.record, .passthrough])
    func `nonreplay leases retain no continuation`(_ mode: ScenarioMode) throws {
        weak var retained: Probe?
        let lease: SequentialTrackLease<Probe, Void>
        do {
            let initial = Probe(-1)
            retained = initial
            let track = try SequentialTrack(id: ExecutionFixtures.track("live"), values: preparedValues([Probe(1)]))
            lease = try SequentialTrackLease(
                track: track, baseline: mode == .record ? track.records : [], baselineHeader: (), mode: mode,
                reporter: DiagnosticReporter(
                    scenarioID: ScenarioID(rawValue: "live"), definition: ScenarioDefinition()),
                admission: ExecutionAdmission(), continuationPolicy: .fallback(initial))
        }
        #expect(retained == nil)
        #expect(throws: SequentialOperationFailure.self) { try lease.consumeNext() }
        lease.close()
    }

    private func makeLease(kind: PolicyKind) throws -> (SequentialTrackLease<Probe, Void>, Witnesses) {
        var witnesses = Witnesses()
        let consumed = Probe(1)
        let unread = Probe(2)
        let initial = Probe(-1)
        witnesses.consumed = consumed
        witnesses.unread = unread
        witnesses.initial = initial
        let track = try SequentialTrack(
            id: ExecutionFixtures.track("lifetime"), values: preparedValues([consumed, unread]))
        let lease = try SequentialTrackLease(
            track: track, baseline: track.records, baselineHeader: (), mode: .replay,
            reporter: DiagnosticReporter(
                scenarioID: ScenarioID(rawValue: "lifetime"), definition: ScenarioDefinition()),
            admission: ExecutionAdmission(), continuationPolicy: kind.policy(initial))
        return (lease, witnesses)
    }
}
