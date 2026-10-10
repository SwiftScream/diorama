import DioramaCore
import Foundation
import Synchronization
import Testing

private final class ManagedJournal: Sendable {
    let events = Mutex<[String]>([])
    let reenter = Mutex<(@Sendable () throws -> Void)?>(nil)
    let freezes = Mutex(0)
    let validations = Mutex(0)
    let transforms = Mutex(0)
    let scheduling = Mutex<SchedulingLease?>(nil)
}

private struct ManagedCounter: Sendable {
    struct State: Sendable {
        let key: String
        let values: HeaderlessSequentialTrackLease<Int>
        let headers: SequentialTrackLease<Int, String>
        var count = 0
        var drafts: [RecordIdentity: Int] = [:]
    }

    let runtime: SystemRuntime<State>
    let snapshot: SystemSnapshot<Int>

    func increment(fail: Bool = false) throws -> Int {
        try runtime.withActiveState { state, operation in
            state.count += 1
            if fail {
                operation.report(Diagnostic(issue: .system(DiagnosticLabel("counter-mutated"))))
                throw ManagedFailure.expected
            }
            try operation.record(on: state.values, capturing: { state.count }, preparation: .init())
            return state.count
        }
    }

    func begin(journal: ManagedJournal, captured: @Sendable () -> Void = {}) throws -> RecordIdentity {
        try runtime.withActiveState { state, operation in
            try operation.beginRecord(on: state.values, preparation: .init(), capturing: { identity in
                state.drafts[identity] = 40
                captured()
                return identity
            }, freeze: { state, identity in
                journal.freezes.withLock { $0 += 1 }
                return state.drafts.removeValue(forKey: identity)
            })
        }
    }

    func observe(_ identity: RecordIdentity) throws {
        try runtime.withActiveState { state, _ in state.drafts[identity, default: 0] += 1 }
    }
}

private enum ManagedFailure: Error { case expected }

private final class ManagedReleaseProbe: Sendable {
    let released: @Sendable () -> Void
    init(released: @escaping @Sendable () -> Void) {
        self.released = released
    }

    deinit { released() }
}

private struct CounterDefinition: SystemDefinition {
    static let type = ScenarioSystemType("consumer.managed-counter")
    let systemType = type
    let values: SystemTrack<Int, Void>
    let headers: SystemTrack<Int, String>
    let journal: ManagedJournal
    var duplicate = false
    var foreign = false
    var failValidation = false
    var failDependency = false
    var failCleanup = false
    var queueConstructionWork = false

    var tracks: [AnySystemTrack] {
        [values.erased, duplicate ? values.erased : headers.erased]
    }

    init(journal: ManagedJournal = ManagedJournal(), initial: [Int] = []) throws {
        self.journal = journal
        values = try SystemTrack("values", values: initial.map { try ValuePreparation<Int>().admitPrepared($0) },
                                 preparation: ValuePreparation(canonicalize: { value in
                                     journal.transforms.withLock { $0 += 1 }
                                     return value
                                 }, validate: { _ in journal.validations.withLock { $0 += 1 } }))
        headers = try SystemTrack("headers", header: ValuePreparation<String>().admitPrepared("ready"))
    }

    func validate(in context: borrowing SystemValidationContext) throws {
        journal.events.withLock { $0.append("validate-" + context.attachmentID.key.rawValue) }
        guard context.mode != .passthrough else { return }
        #expect(try context.track(headers).header == "ready")
        #expect(try context.track(headers).records.isEmpty)
        try context.validate(values) { content in
            journal.events.withLock { $0.append("baseline-" + content.records.map { String($0.value) }.joined()) }
            if failValidation {
                throw ManagedFailure.expected
            }
        }
    }

    func makeRecordState(in context: borrowing SystemStateContext) throws -> ManagedCounter.State {
        journal.events.withLock { $0.append("activate-" + context.attachmentID.key.rawValue) }
        let lease = try context.lease(for: foreign ? SystemTrack<Int, Void>("values") : values)
        let copy = values
        #expect(try lease === context.lease(for: copy))
        #expect(try context.track(headers).header == "ready")
        return try ManagedCounter.State(key: context.attachmentID.key.rawValue,
                                        values: lease, headers: context.lease(for: headers))
    }

    func makeReplayState(in context: borrowing SystemStateContext) throws -> ManagedCounter.State {
        try makeRecordState(in: context)
    }

    func makeRecordDependency(using runtime: SystemRuntime<ManagedCounter.State>) throws -> ManagedCounter {
        if queueConstructionWork {
            try runtime.withActiveState { state, operation in
                let record = RecordIdentity(trackID: state.values.id, sequence: 0)
                operation.afterCommit {
                    journal.scheduling.withLock { $0 = runtime.scheduling }
                    let capture = ManagedReleaseProbe { journal.events.withLock { $0.append("callback-released") } }
                    _ = try? runtime.scheduling.schedule(after: .zero, for: record) { [capture] in
                        withExtendedLifetime(capture) {}
                        Issue.record("Construction work ran before successful startup")
                    }
                }
            }
        }
        if failDependency {
            throw ManagedFailure.expected
        }
        return ManagedCounter(runtime: runtime, snapshot: runtime.snapshot(\.count))
    }

    func makeReplayDependency(using runtime: SystemRuntime<ManagedCounter.State>) throws -> ManagedCounter {
        try makeRecordDependency(using: runtime)
    }

    func makePassthroughDependency() throws -> ManagedCounter {
        throw ManagedFailure.expected
    }

    func cleanUpRecordState(_ state: ManagedCounter.State) throws {
        journal.events.withLock { $0.append("cleanup-" + state.key) }
        if failCleanup {
            throw ManagedFailure.expected
        }
    }

    func cleanUpReplayState(_ state: ManagedCounter.State) throws {
        try cleanUpRecordState(state)
    }
}

struct ManagedDefinitionTests {
    @Test func `failed construction releases queued callback captures and closes escaped scheduling`() throws {
        var model = try CounterDefinition()
        model.queueConstructionWork = true
        model.failDependency = true
        let system = try ScenarioSystem(named: "counter", definition: model)
        do {
            _ = try start(system)
            Issue.record("Expected failed construction")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.report.diagnostics.contains {
                $0.diagnostic.issue == .scheduling(.logicalTime(.notStarted))
            })
        }
        #expect(model.journal.events.withLock { $0.contains("callback-released") })
        let scheduling = try #require(model.journal.scheduling.withLock { $0 })
        let record = RecordIdentity(trackID: system.attachment.trackIDs[0], sequence: 0)
        do {
            try scheduling.schedule(after: .zero, for: record) { Issue.record("Closed service delivered") }
            Issue.record("Failed startup left scheduling open")
        } catch {
            #expect(error.diagnostic.issue == .scheduling(.logicalTime(.executionClosed)))
        }
    }

    @Test func `registration racing finish freezes once after unlocking managed state`() async throws {
        let model = try CounterDefinition()
        let system = try ScenarioSystem(named: "counter", definition: model)
        let execution = try start(system)
        let counter = try execution.dependency(system)
        let captured = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let timeout = DispatchWorkItem { release.signal() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel(); release.signal() }
        let registering = Task {
            try? counter.begin(journal: model.journal) {
                captured.continuation.finish()
                release.wait()
            }
        }
        for await _ in captured.stream {}
        let finishing = Task { await execution.finish() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !counter.runtime.isClosed, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(counter.runtime.isClosed)
        release.signal()
        #expect(await registering.value == nil)
        let final = await finishing.value
        #expect(model.journal.freezes.withLock { $0 } == 1)
        #expect(final.definition == nil)
        #expect(final.usage[0].tracks[0].activity == .record(recordedCount: 0, incompleteCount: 1))
        #expect(final.report.diagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.leaseClosed), .verification(.recordingNotAdmitted),
        ])
    }

    @Test func `failed dependency construction unwinds all managed states in reverse order`() throws {
        var model = try CounterDefinition()
        let first = try ScenarioSystem(named: "first", definition: model)
        let second = try ScenarioSystem(named: "second", definition: model)
        model.failDependency = true
        let third = try ScenarioSystem(named: "third", definition: model)
        #expect(throws: ScenarioStartupFailure.self) {
            try ScenarioExecution.start(
                definition: ScenarioDefinition(attachments: [first.attachment, second.attachment, third.attachment]),
                scenarioID: .init(rawValue: "rollback"), defaultMode: .record,
                systems: [AnyScenarioSystem(third), AnyScenarioSystem(first), AnyScenarioSystem(second)])
        }
        #expect(Array(model.journal.events.withLock { $0 }.suffix(3)) == [
            "cleanup-third", "cleanup-second", "cleanup-first",
        ])
    }

    @Test func `callbacks and cancellation destruction reenter only after state commits`() async throws {
        let model = try CounterDefinition()
        let system = try ScenarioSystem(named: "counter", definition: model)
        let execution = try start(system)
        let counter = try execution.dependency(system)
        let callbacks = Mutex<[Int]>([])
        var capture: ManagedReleaseProbe? = ManagedReleaseProbe {
            callbacks.withLock { $0.append(counter.snapshot.value) }
            #expect((try? counter.increment()) == 8)
        }
        let record = RecordIdentity(trackID: system.attachment.trackIDs[0], sequence: 0)
        let pending = try counter.runtime.scheduling.schedule(after: .seconds(3600), for: record) { [capture] in
            withExtendedLifetime(capture) {}
            Issue.record("Canceled callback ran")
        }
        capture = nil
        try counter.runtime.withActiveState { state, operation in
            state.count = 7
            #expect(pending.cancel())
            #expect(callbacks.withLock { $0.isEmpty })
            operation.afterCommit { callbacks.withLock { $0.append(counter.snapshot.value) } }
        }
        #expect(callbacks.withLock { $0 } == [7, 8])
        #expect(await execution.finish().report.diagnostics.isEmpty)
    }

    @Test func `registration under protection rejects before launching callbacks`() async throws {
        let model = try CounterDefinition()
        let system = try ScenarioSystem(named: "counter", definition: model)
        let execution = try start(system)
        let counter = try execution.dependency(system)
        let record = RecordIdentity(trackID: system.attachment.trackIDs[0], sequence: 0)
        #expect(throws: SchedulingFailure.self) {
            try counter.runtime.withActiveState { _, _ in
                try counter.runtime.scheduling.schedule(after: .zero, for: record) {
                    Issue.record("Protected registration launched work")
                }
            }
        }
        #expect(await execution.finish().report.diagnostics.map(\.diagnostic.issue) == [
            .scheduling(.protectedOperation),
        ])
    }

    @Test func `typed declarations resolved validation and independent runs`() async throws {
        let model = try CounterDefinition(initial: [1])
        let first = try ScenarioSystem(named: "first", definition: model)
        let second = try ScenarioSystem(named: "second", definition: model)
        let loadedFirst = try ScenarioAttachment(id: first.attachment.id)
            .adding(HeaderlessSequentialTrack(id: first.attachment.trackIDs[0], values: [
                ValuePreparation<Int>().admitPrepared(9),
            ]))
            .adding(SequentialTrack<Int, String>(id: first.attachment.trackIDs[1],
                                                 header: ValuePreparation<String>().admitPrepared("ready")))
        let baseline = try ScenarioDefinition(attachments: [loadedFirst, second.attachment])
        for _ in 0..<2 {
            let execution = try ScenarioExecution.start(definition: baseline, scenarioID: .init(rawValue: "counter"),
                                                        defaultMode: .record,
                                                        systems: [AnyScenarioSystem(second), AnyScenarioSystem(first)])
            let firstCounter = try execution.dependency(first)
            let secondCounter = try execution.dependency(second)
            #expect(try firstCounter.increment() == 1)
            #expect(try firstCounter.increment() == 2)
            #expect(try secondCounter.increment() == 1)
            _ = await execution.finish()
            #expect(firstCounter.snapshot.value == 2)
            #expect(throws: (any Error).self) { try firstCounter.increment() }
        }
        #expect(Array(model.journal.events.withLock { $0 }.prefix(6)) == [
            "validate-first", "baseline-9", "validate-second", "baseline-1", "activate-first", "activate-second",
        ])
        #expect(model.journal.validations.withLock { $0 } == 4)
        #expect(model.journal.transforms.withLock { $0 } == 0)
    }

    @Test func `duplicate foreign and later validation failures`() throws {
        var model = try CounterDefinition()
        model.duplicate = true
        #expect(throws: ScenarioDefinitionError.self) { try ScenarioSystem(named: "counter", definition: model) }
        model.duplicate = false
        model.foreign = true
        let foreign = try ScenarioSystem(named: "foreign", definition: model)
        #expect(throws: ScenarioStartupFailure.self) { try start(foreign) }
        model.foreign = false
        let first = try ScenarioSystem(named: "first", definition: model)
        model.failValidation = true
        let last = try ScenarioSystem(named: "last", definition: model)
        model.journal.events.withLock { $0 = [] }
        #expect(throws: ScenarioStartupFailure.self) {
            try ScenarioExecution.start(
                definition: ScenarioDefinition(attachments: [first.attachment, last.attachment]),
                scenarioID: .init(rawValue: "counter"), defaultMode: .record,
                systems: [AnyScenarioSystem(first), AnyScenarioSystem(last)])
        }
        #expect(model.journal.events.withLock { !$0.contains(where: { $0.hasPrefix("activate") }) })
    }

    @Test func `throwing operation commits snapshot before reentrant throwing sink`() async throws {
        let model = try CounterDefinition()
        let system = try ScenarioSystem(named: "counter", definition: model)
        let execution = try start(system, sink: DiagnosticSink { _ in
            let callback = model.journal.reenter.withLock { callback in
                let result = callback
                callback = nil
                return result
            }
            try callback?()
            throw ManagedFailure.expected
        })
        let counter = try execution.dependency(system)
        model.journal.reenter.withLock { $0 = { () throws in
            #expect(counter.snapshot.value == 1)
            #expect(try counter.increment() == 2)
        } }
        #expect(throws: ManagedFailure.self) { try counter.increment(fail: true) }
        #expect(counter.snapshot.value == 2)
        let final = await execution.finish()
        #expect(final.report.diagnostics.map(\.diagnostic.issue) == [
            .system(DiagnosticLabel("counter-mutated")), .sinkFailed,
        ])
        #expect(model.journal.events.withLock { $0.last } == "cleanup-counter")
    }

    @Test func `incremental freeze uses managed state once and rejects late observations`() async throws {
        let model = try CounterDefinition()
        let system = try ScenarioSystem(named: "counter", definition: model)
        let execution = try start(system)
        let counter = try execution.dependency(system)
        let record = try counter.begin(journal: model.journal)
        try counter.observe(record)
        async let firstFinish = execution.finish()
        async let secondFinish = execution.finish()
        let (first, second) = await (firstFinish, secondFinish)
        #expect(first.report == second.report)
        #expect(first.report.recordingHealth.isHealthy)
        let attachment = try #require(first.definition?.attachments.first)
        #expect(try attachment.track(system.attachment.trackIDs[0], as: Int.self)?.records.map(\.value) == [41])
        #expect(model.journal.freezes.withLock { $0 } == 1)
        #expect(throws: (any Error).self) { try counter.observe(record) }
        #expect(first.report.diagnostics.isEmpty)
    }

    @Test func `dependency failure cleans created state and retains cleanup failure`() throws {
        var model = try CounterDefinition()
        model.failDependency = true
        model.failCleanup = true
        let system = try ScenarioSystem(named: "counter", definition: model)
        do {
            _ = try start(system)
            Issue.record("Expected dependency construction failure")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.report.diagnostics.contains { $0.diagnostic.issue == .lifecycle(.cleanupFailed) })
            #expect(failure.report.diagnostics.contains { $0.diagnostic.issue == .lifecycle(.activationFailed) })
        }
        #expect(model.journal.events.withLock { $0.filter { $0 == "cleanup-counter" }.count } == 1)
    }

    private func start(_ system: ScenarioSystem<ManagedCounter>, sink: DiagnosticSink? = nil)
        throws -> ScenarioExecution
    {
        try ScenarioExecution.start(definition: ScenarioDefinition(attachments: [system.attachment]),
                                    scenarioID: .init(rawValue: "counter"), defaultMode: .record,
                                    systems: [AnyScenarioSystem(system)], sink: sink)
    }
}
