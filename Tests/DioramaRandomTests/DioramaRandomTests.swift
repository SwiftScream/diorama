import DioramaCore
import DioramaRandom
import Foundation
import Synchronization
import Testing

struct DioramaRandomTests {
    @Test
    func `record returns a known source sequence through shared references`() async throws {
        let key = AttachmentKey(rawValue: "record")
        let probe = SourceProbe(sequences: [[7, 11, 13]])
        let instance = try DioramaRandomSystem.instance(for: key.rawValue) {
            probe.makeSource()
        }
        let execution = try start(mode: .record, instance: instance)
        var generator = try execution.dependency(instance)
        var alias = generator

        #expect(generator.next() == 7)
        #expect(alias.next() == 11)
        #expect(generator.next() == 13)
        #expect(probe.callCount == 3)
        #expect(await execution.finish().report.diagnostics.isEmpty)
        #expect(probe.releaseCount == 1)
    }

    @Test
    func `passthrough uses only its live source`() async throws {
        let key = AttachmentKey(rawValue: "passthrough")
        let probe = SourceProbe(sequences: [[21, 22]])
        let attachment = try attachment(key: key, values: [1, 2, 3])
        let instance = try DioramaRandomSystem.instance(for: key.rawValue) { probe.makeSource() }

        let definition = try ScenarioDefinition(attachments: [attachment])
        let execution = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "random-passthrough"), defaultMode: .passthrough,
            systems: [AnyScenarioSystem(instance)])
        var generator = try execution.dependency(instance)

        #expect(generator.next() == 21)
        #expect(generator.next() == 22)
        #expect(probe.callCount == 2)
        #expect(await execution.finish().report.diagnostics.isEmpty)
    }

    @Test
    func `named random systems retain independent sources`() async throws {
        let first = AttachmentKey(rawValue: "first")
        let second = AttachmentKey(rawValue: "second")
        let firstProbe = SourceProbe(sequences: [[1, 2]])
        let secondProbe = SourceProbe(sequences: [[10, 20]])
        let firstInstance = try DioramaRandomSystem.instance(for: first.rawValue) { firstProbe.makeSource() }
        let secondInstance = try DioramaRandomSystem.instance(for: second.rawValue) { secondProbe.makeSource() }

        let definition = try ScenarioDefinition(attachments: [
            firstInstance.attachment,
            secondInstance.attachment,
        ])
        let execution = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "random-independent"), defaultMode: .record,
            systems: [
                AnyScenarioSystem(secondInstance),
                AnyScenarioSystem(firstInstance),
            ])
        var firstGenerator = try execution.dependency(firstInstance)
        var secondGenerator = try execution.dependency(secondInstance.dependencyKey)

        #expect(secondGenerator.next() == 10)
        #expect(firstGenerator.next() == 1)
        #expect(secondGenerator.next() == 20)
        #expect(firstGenerator.next() == 2)
        #expect(firstProbe.callCount == 2)
        #expect(secondProbe.callCount == 2)
        #expect(await execution.finish().report.diagnostics.isEmpty)
    }

    @Test
    func `source factory creates fresh state for every execution`() async throws {
        let key = AttachmentKey(rawValue: "fresh")
        let probe = SourceProbe(sequences: [[31], [41]])
        let instance = try DioramaRandomSystem.instance(for: key.rawValue) {
            probe.makeSource()
        }

        let definition = try ScenarioDefinition(attachments: [instance.attachment])

        let firstExecution = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "random-fresh"), defaultMode: .record,
            systems: [AnyScenarioSystem(instance)])
        var first = try firstExecution.dependency(instance)
        #expect(first.next() == 31)
        _ = await firstExecution.finish()

        let secondExecution = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "random-fresh"), defaultMode: .record,
            systems: [AnyScenarioSystem(instance)])
        var second = try secondExecution.dependency(instance.dependencyKey)
        #expect(second.next() == 41)
        _ = await secondExecution.finish()

        #expect(probe.creationCount == 2)
        #expect(probe.releaseCount == 2)
    }

    @Test
    func `one attachment serializes concurrent source access and recording`() async throws {
        let key = AttachmentKey(rawValue: "concurrent")
        let values = Array(0..<UInt64(100))
        let probe = SourceProbe(sequences: [values], operationDelay: 0.001)
        let instance = try DioramaRandomSystem.instance(for: key.rawValue) { probe.makeSource() }
        let execution = try start(mode: .record, instance: instance)
        let generator = try execution.dependency(instance)
        let observed = await withTaskGroup(of: UInt64.self, returning: [UInt64].self) { group in
            for _ in values {
                group.addTask {
                    var generator = generator
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
        #expect(probe.maximumConcurrentCalls == 1)
        #expect(probe.callCount == values.count)
        #expect(await execution.finish().report.diagnostics.isEmpty)
    }

    @Test
    func `finish releases the source and closes an escaped generator`() async throws {
        let key = AttachmentKey(rawValue: "closed")
        let probe = SourceProbe(sequences: [[51, 52]])
        let instance = try DioramaRandomSystem.instance(for: key.rawValue) { probe.makeSource() }
        let execution = try start(mode: .record, instance: instance)
        var generator = try execution.dependency(instance)

        #expect(generator.next() == 51)
        let result = await execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(probe.releaseCount == 1)
        #expect(generator.next() == 0)
        #expect(probe.callCount == 1)
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.leaseClosed),
        ])
    }

    @Test
    func `default source registration activates in passthrough`() async throws {
        let key = AttachmentKey(rawValue: "default")
        let instance = try DioramaRandomSystem.instance(for: key.rawValue)
        let execution = try start(mode: .passthrough, instance: instance)
        var generator = try execution.dependency(instance)

        _ = generator.next()
        #expect(await execution.finish().report.diagnostics.isEmpty)
    }

    private func start(
        mode: ScenarioMode,
        instance: ScenarioSystem<any RandomNumberGenerator & Sendable>) throws -> ScenarioExecution
    {
        let definition = try ScenarioDefinition(attachments: [instance.attachment])
        return try ScenarioExecution.start(
            definition: definition,
            scenarioID: ScenarioID(rawValue: "random-" + instance.attachment.id.key.rawValue), defaultMode: mode,
            systems: [AnyScenarioSystem(instance)])
    }

    private func attachment(key: AttachmentKey, values: [UInt64]) throws -> ScenarioAttachment {
        let layout = try DioramaRandomSystem.instance(for: key.rawValue).attachment
        return try ScenarioAttachment(id: layout.id).adding(
            SequentialTrack(
                id: layout.trackIDs[0],
                values: preparedValues(values)))
    }

    private func preparedValues(_ values: [UInt64]) throws -> [PreparedValue<UInt64>] {
        let definition = try ScenarioDefinition()
        let reporter = DiagnosticReporter(
            scenarioID: ScenarioID(rawValue: "random-test-values"),
            definition: definition)
        let preparation = ValuePreparation<UInt64>()
        return try values.map { value in
            try preparation.prepare(
                capturing: { value },
                purpose: .replay,
                reporter: reporter)
        }
    }
}

private final class SourceProbe: Sendable {
    private struct State: Sendable {
        var sequences: [[UInt64]]
        var nextSequence = 0
        var creationCount = 0
        var releaseCount = 0
        var callCount = 0
        var concurrentCalls = 0
        var maximumConcurrentCalls = 0
    }

    private let state: Mutex<State>
    private let operationDelay: TimeInterval

    init(sequences: [[UInt64]], operationDelay: TimeInterval = 0) {
        state = Mutex(State(sequences: sequences))
        self.operationDelay = operationDelay
    }

    var creationCount: Int {
        state.withLock { $0.creationCount }
    }

    var releaseCount: Int {
        state.withLock { $0.releaseCount }
    }

    var callCount: Int {
        state.withLock { $0.callCount }
    }

    var maximumConcurrentCalls: Int {
        state.withLock { $0.maximumConcurrentCalls }
    }

    func makeSource() -> KnownSource {
        let values = state.withLock { state in
            let values = state.sequences[state.nextSequence]
            state.nextSequence += 1
            state.creationCount += 1
            return values
        }
        return KnownSource(values: values, probe: self)
    }

    func observe(_ value: UInt64) -> UInt64 {
        state.withLock { state in
            state.concurrentCalls += 1
            state.maximumConcurrentCalls = max(
                state.maximumConcurrentCalls,
                state.concurrentCalls)
            state.callCount += 1
        }
        if operationDelay > 0 {
            Thread.sleep(forTimeInterval: operationDelay)
        }
        state.withLock { $0.concurrentCalls -= 1 }
        return value
    }

    func released() {
        state.withLock { $0.releaseCount += 1 }
    }
}

private final class KnownSource: RandomNumberGenerator, Sendable {
    private struct State: Sendable {
        var position = 0
    }

    private let values: [UInt64]
    private let probe: SourceProbe
    private let state = Mutex(State())

    init(values: [UInt64], probe: SourceProbe) {
        self.values = values
        self.probe = probe
    }

    func next() -> UInt64 {
        let value = state.withLock { state in
            let value = values[state.position]
            state.position += 1
            return value
        }
        return probe.observe(value)
    }

    deinit {
        probe.released()
    }
}
