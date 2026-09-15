import DioramaCore
import DioramaRandom
import Synchronization
import Testing

struct DioramaRandomReplayTests {
    @Test
    func `replay returns raw boundary values without constructing a source`() async throws {
        let key = AttachmentKey(rawValue: "replay-boundaries")
        let probe = ReplaySourceProbe()
        let instance = try DioramaRandomSystem.instance(for: key) { probe.makeSource() }
        let execution = try replayExecution(
            key: key,
            values: [0, .max],
            instance: instance)
        var generator = try execution.dependency(instance)

        #expect(generator.next() == 0)
        #expect(generator.next() == UInt64.max)
        #expect(probe.factoryCallCount == 0)
        #expect(probe.sourceCallCount == 0)
        #expect(await (execution.finish()).report.diagnostics.isEmpty)
    }

    @Test
    func `replay never evaluates a trapping source factory`() throws {
        let key = AttachmentKey(rawValue: "replay-trapping-factory")
        let instance = try DioramaRandomSystem.instance(for: key) { forbiddenLiveSource() }
        let execution = try replayExecution(
            key: key,
            values: [71],
            instance: instance)
        var generator = try execution.dependency(instance.dependencyKey)

        #expect(generator.next() == 71)
    }

    @Test
    func `replay exhaustion notifies the handler and returns zero`() async throws {
        let key = AttachmentKey(rawValue: "replay-exhaustion")
        let notifications = Mutex<[ReportedDiagnostic]>([])
        let sink = DiagnosticSink { diagnostic in
            notifications.withLock { $0.append(diagnostic) }
        }
        let instance = try DioramaRandomSystem.instance(for: key) { forbiddenLiveSource() }
        let execution = try replayExecution(
            key: key,
            values: [81],
            instance: instance,
            sink: sink)
        var generator = try execution.dependency(instance)

        #expect(generator.next() == 81)
        #expect(generator.next() == 0)
        #expect(generator.next() == 0)

        let reported = notifications.withLock { $0 }
        #expect(reported.map(\.diagnostic.issue) == [
            .sequential(.replayExhausted(availableCount: 1)),
            .sequential(.replayExhausted(availableCount: 1)),
        ])
        #expect(reported.compactMap(\.diagnostic.context.recordIdentity?.sequence) == [1, 2])
        #expect(await (execution.finish()).report.diagnostics == reported)
    }

    @Test
    func `empty replay reports zero available values and returns zero`() throws {
        let key = AttachmentKey(rawValue: "replay-empty")
        let notifications = Mutex<[ReportedDiagnostic]>([])
        let sink = DiagnosticSink { diagnostic in
            notifications.withLock { $0.append(diagnostic) }
        }
        let probe = ReplaySourceProbe()
        let instance = try DioramaRandomSystem.instance(for: key) { probe.makeSource() }
        let execution = try replayExecution(
            key: key,
            values: [],
            instance: instance,
            sink: sink)
        var generator = try execution.dependency(instance)

        #expect(generator.next() == 0)
        #expect(notifications.withLock { $0.map(\.diagnostic.issue) } == [
            .sequential(.replayExhausted(availableCount: 0)),
        ])
        #expect(notifications.withLock { $0.first?.diagnostic.context.recordIdentity?.sequence } == 0)
        #expect(probe.factoryCallCount == 0)
        #expect(probe.sourceCallCount == 0)
    }

    @Test
    func `replay executions and concurrent references keep independent atomic cursors`() async throws {
        let key = AttachmentKey(rawValue: "replay-concurrent")
        let values = Array(1...100).map(UInt64.init)
        let probe = ReplaySourceProbe()
        let instance = try DioramaRandomSystem.instance(for: key) { probe.makeSource() }
        let definition = try ScenarioDefinition(
            id: ScenarioID(rawValue: "random-replay-concurrent"),
            defaultMode: .replay,
            attachments: [replayAttachment(key: key, values: values)])

        let firstExecution = try ScenarioExecution.start(definition: definition, systems: [AnyScenarioSystem(instance)])
        let firstGenerator = try firstExecution.dependency(instance)
        let observed = await withTaskGroup(of: UInt64.self, returning: [UInt64].self) { group in
            for _ in values {
                group.addTask {
                    var generator = firstGenerator
                    return generator.next()
                }
            }
            var results: [UInt64] = []
            for await value in group {
                results.append(value)
            }
            return results
        }
        #expect(observed.sorted() == values)
        #expect(await (firstExecution.finish()).report.diagnostics.isEmpty)

        let secondExecution = try ScenarioExecution.start(
            definition: definition,
            systems: [AnyScenarioSystem(instance)])
        var secondGenerator = try secondExecution.dependency(instance.dependencyKey)
        #expect(secondGenerator.next() == 1)
        #expect(await (secondExecution.finish()).report.diagnostics.isEmpty)
        #expect(probe.factoryCallCount == 0)
        #expect(probe.sourceCallCount == 0)
    }

    @Test
    func `finish closes escaped generators offline in every mode`() async throws {
        try await assertClosedGenerator(mode: .record, expectedSourceCount: 1)
        try await assertClosedGenerator(mode: .passthrough, expectedSourceCount: 1)
        try await assertClosedGenerator(mode: .replay, expectedSourceCount: 0)
    }
}

private func assertClosedGenerator(
    mode: ScenarioMode,
    expectedSourceCount: Int) async throws
{
    let key = AttachmentKey(rawValue: "closed-" + String(describing: mode))
    let probe = ReplaySourceProbe()
    let instance = try DioramaRandomSystem.instance(for: key) { probe.makeSource() }
    let definition = try ScenarioDefinition(
        id: ScenarioID(rawValue: "random-closed-" + String(describing: mode)),
        defaultMode: mode,
        attachments: [replayAttachment(key: key, values: [51, 52])])
    let execution = try ScenarioExecution.start(
        definition: definition,
        systems: [AnyScenarioSystem(instance)])
    var generator = try execution.dependency(instance)

    #expect(generator.next() == 51)
    #expect(await (execution.finish()).report.diagnostics.isEmpty)
    #expect(probe.factoryCallCount == expectedSourceCount)
    #expect(probe.releaseCount == expectedSourceCount)
    #expect(generator.next() == 0)
    #expect(probe.sourceCallCount == expectedSourceCount)
    #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [
        .lifecycle(.leaseClosed),
    ])
}

private func replayExecution(
    key: AttachmentKey,
    values: [UInt64],
    instance: ScenarioSystem<any RandomNumberGenerator & Sendable>,
    sink: DiagnosticSink? = nil) throws -> ScenarioExecution
{
    let definition = try ScenarioDefinition(
        id: ScenarioID(rawValue: "random-" + key.rawValue),
        defaultMode: .replay,
        attachments: [replayAttachment(key: key, values: values)])
    return try ScenarioExecution.start(definition: definition, systems: [AnyScenarioSystem(instance)], sink: sink)
}

private func replayAttachment(key: AttachmentKey, values: [UInt64]) throws -> ScenarioAttachment {
    try ScenarioAttachment(id: DioramaRandomSystem.attachmentID(for: key)).adding(
        SequentialTrack(
            id: DioramaRandomSystem.trackID(for: key),
            values: preparedValues(values)))
}

private func preparedValues(_ values: [UInt64]) throws -> [PreparedValue<UInt64>] {
    let definition = try ScenarioDefinition(
        id: ScenarioID(rawValue: "random-replay-test-values"),
        defaultMode: .replay)
    let reporter = DiagnosticReporter(definition: definition)
    let preparation = ValuePreparation<UInt64>()
    return try values.map { value in
        try preparation.prepare(
            capturing: { value },
            purpose: .replay,
            reporter: reporter)
    }
}

private func forbiddenLiveSource() -> SystemRandomNumberGenerator {
    fatalError("Replay must not initialize a live random source")
}

private final class ReplaySourceProbe: Sendable {
    private struct State: Sendable {
        var factoryCallCount = 0
        var sourceCallCount = 0
        var releaseCount = 0
    }

    private let state = Mutex(State())

    var factoryCallCount: Int {
        state.withLock { $0.factoryCallCount }
    }

    var sourceCallCount: Int {
        state.withLock { $0.sourceCallCount }
    }

    var releaseCount: Int {
        state.withLock { $0.releaseCount }
    }

    func makeSource() -> ReplayKnownSource {
        state.withLock { $0.factoryCallCount += 1 }
        return ReplayKnownSource(probe: self)
    }

    func sourceCalled() {
        state.withLock { $0.sourceCallCount += 1 }
    }

    func sourceReleased() {
        state.withLock { $0.releaseCount += 1 }
    }
}

private final class ReplayKnownSource: RandomNumberGenerator, Sendable {
    private let probe: ReplaySourceProbe

    init(probe: ReplaySourceProbe) {
        self.probe = probe
    }

    func next() -> UInt64 {
        probe.sourceCalled()
        return 51
    }

    deinit {
        probe.sourceReleased()
    }
}
