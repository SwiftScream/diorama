@testable import DioramaCore
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
