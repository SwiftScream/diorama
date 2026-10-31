@testable import DioramaCore
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ReplayHeaderTests {
    @Test
    func `direct and managed header reads preserve claims and preparation`() async throws {
        let validations = Mutex(0)
        let transforms = Mutex(0)
        let preparation = ValuePreparation<String>(normalize: { value in
            transforms.withLock { $0 += 1 }
            return value
        }, validate: { _ in validations.withLock { $0 += 1 } })
        let (execution, dependency) = try await start(header: "origin", headerPreparation: preparation)
        let lease = try dependency.state.withLock { state, _ in state }
        let admittedValidations = validations.withLock { $0 }
        #expect(admittedValidations > 0)
        #expect(try lease.replayHeader() == "origin")
        #expect(try dependency.state.withLock { state, operation in
            try operation.replayHeader(on: state)
        } == "origin")
        #expect(validations.withLock { $0 } == admittedValidations)
        #expect(transforms.withLock { $0 } == 0)
        #expect(try lease.consumeNext() == 11)
        #expect(try lease.replayHeader() == "origin")
        let result = await execution.finish()
        let usage = try #require(result.usage.first?.tracks.first)
        #expect(usage.claimedRecords.map(\.identity.sequence) == [0])
        #expect(usage.claimedRecords.map(\.isConsumed) == [true])
        #expect(usage.unclaimedRecords.map(\.sequence) == [1])
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test
    func `empty tracks and absent optional header values remain readable`() async throws {
        let (execution, dependency) = try await start(header: Int?.none, values: [])
        let lease = try dependency.state.withLock { state, _ in state }
        #expect(try lease.replayHeader() == nil)
        #expect(try dependency.state.withLock { state, operation in
            try operation.replayHeader(on: state)
        } == nil)
        let result = await execution.finish()
        #expect(result.usage.first?.tracks.first?.activity == .replay(claimedCount: 0, unclaimedCount: 0))
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test
    func `wrong mode and closed reads throw without record continuation`() async throws {
        let (execution, dependency) = try await start(header: 42, mode: .record)
        let lease = try dependency.state.withLock { state, _ in state }
        #expect(throws: SequentialOperationFailure.self) { try lease.replayHeader() }
        #expect(throws: SequentialOperationFailure.self) {
            try dependency.state.withLock { state, operation in try operation.replayHeader(on: state) }
        }
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == Array(
            repeating: .sequential(.wrongMode(expected: .replay, actual: .record)), count: 2))
        #expect(result.report.diagnostics.allSatisfy { $0.diagnostic.context == .track(lease.id) })
        #expect(throws: SequentialOperationFailure.self) { try lease.replayHeader() }
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
        #expect(await execution.finish().report == result.report)
    }

    @Test
    func `header reads ignore record exhaustion and continuation but reject closure`() async throws {
        let (execution, dependency) = try await start(header: 42, values: [])
        let lease = try dependency.state.withLock { state, _ in state }
        #expect(try lease.consumeNext() == -1)
        #expect(try lease.replayHeader() == 42)
        #expect(try lease.replayHeader() == 42)
        let result = await execution.finish()
        #expect(result.report.diagnostics.count == 1)
        #expect(throws: SequentialOperationFailure.self) { try lease.replayHeader() }
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
        #expect(await execution.finish().report == result.report)
    }

    @Test
    func `admission closure rejects header reads before track storage detaches`() async throws {
        let stopped = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let (execution, dependency) = try await start(header: 42, onStop: {
            stopped.continuation.finish()
            for await _ in release.stream {}
        })
        let lease = try dependency.state.withLock { state, _ in state }
        let finish = Task { await execution.finish() }
        for await _ in stopped.stream {}
        #expect(lease.baselineHeader() == 42)
        #expect(throws: SequentialOperationFailure.self) { try lease.replayHeader() }
        release.continuation.finish()
        let result = await finish.value
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
        #expect(result.report.diagnostics.first?.diagnostic.context == .track(lease.id))
        #expect(lease.baselineHeader() == nil)
    }

    @Test
    func `closed leases release reference headers while callers own their returned snapshots`() throws {
        let lease: SequentialTrackLease<Int, HeaderProbe>
        weak var witness: HeaderProbe?
        do {
            let header = HeaderProbe()
            witness = header
            let track = try SequentialTrack<Int, HeaderProbe>(
                id: ExecutionFixtures.track("header-lifetime"),
                header: ValuePreparation<HeaderProbe>().admitPrepared(header))
            lease = try SequentialTrackLease(
                track: track, baseline: [], baselineHeader: header, mode: .replay,
                reporter: DiagnosticReporter(scenarioID: .init(rawValue: "header-lifetime"),
                                             definition: ScenarioDefinition()),
                admission: ExecutionAdmission())
        }
        var snapshot: HeaderProbe? = try lease.replayHeader()
        #expect(snapshot === witness)
        lease.close()
        #expect(witness != nil)
        withExtendedLifetime(snapshot) {}
        snapshot = nil
        #expect(witness == nil)
        #expect(throws: SequentialOperationFailure.self) { try lease.replayHeader() }
    }

    private final class HeaderProbe: Sendable {}

    private func start<Header: Sendable>(
        header: Header, values: [Int] = [11, 22], mode: ScenarioMode = .replay,
        headerPreparation: ValuePreparation<Header> = .init(),
        onStop: @escaping @Sendable () async -> Void = {}) async throws
        -> (ScenarioExecution, SystemExecution<SequentialTrackLease<Int, Header>>)
    {
        let definition = try HeaderDefinition(
            track: TrackDefinition(
                "values", header: ValuePreparation<Header>().admitPrepared(header),
                values: values.map { try ValuePreparation<Int>().admitPrepared($0) },
                headerPreparation: headerPreparation, continuationPolicy: .fallback(-1)),
            onStop: onStop)
        let system = try ScenarioSystem(named: "headers", definition: definition)
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]),
            scenarioID: ScenarioID(rawValue: "replay-header"), defaultMode: mode,
            systems: [AnyScenarioSystem(system)])
        guard case let .managed(dependency) = try execution.dependency(system) else {
            throw HeaderFixtureError.unexpectedMode
        }
        return (execution, dependency)
    }
}

private enum HeaderFixtureError: Error { case unexpectedMode }

private struct HeaderDefinition<Header: Sendable>: SystemDefinition {
    enum Dependency: Sendable {
        case managed(SystemExecution<SequentialTrackLease<Int, Header>>)
        case native
    }

    let systemType = ScenarioSystemType("replay-header")
    let track: TrackDefinition<Int, Header>
    let onStop: @Sendable () async -> Void
    var tracks: [AnyTrackDefinition] {
        [track.erased]
    }

    var record: SystemModeDefinition<SequentialTrackLease<Int, Header>, Dependency> {
        .init(makeState: { try $0.lease(for: track) }, makeDependency: { .managed($0) },
              requestStop: { _, _ in await onStop() })
    }

    var replay: SystemModeDefinition<SequentialTrackLease<Int, Header>, Dependency> {
        record
    }

    var passthrough: SystemModeDefinition<Void, Dependency> {
        .init(makeDependency: { .native })
    }
}
