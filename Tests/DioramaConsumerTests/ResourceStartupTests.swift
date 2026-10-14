import DioramaCore
import Testing

struct ResourceStartupTests {
    @Test(arguments: ["validation", "construction", "dependency"])
    func `startup failures preserve the factory and Core ownership boundary`(point: String) async throws {
        let journal = ResourceJournal()
        let weak = ResourceWeakBox()
        let first = try ScenarioSystem(named: "first", definition: ResourceDefinition(journal: journal, weak: weak))
        var failing = ResourceDefinition(journal: journal, weak: weak)
        failing.failValidation = point == "validation"
        failing.failConstruction = point == "construction"
        failing.failDependency = point == "dependency"
        let second = try ScenarioSystem(named: "second", definition: failing)
        do {
            _ = try await ScenarioExecution.start(
                definition: ScenarioDefinition(attachments: [first.attachment, second.attachment]),
                scenarioID: .init(rawValue: "rollback"), defaultMode: .record,
                systems: [AnyScenarioSystem(first), AnyScenarioSystem(second)])
            Issue.record("Failure returned an execution")
        } catch let failure as ScenarioStartupFailure {
            let expected = point == "validation" ? [] : point == "dependency" ?
                [first.attachment.id, second.attachment.id] : [first.attachment.id]
            #expect(failure.cleanup.map(\.attachmentID) == expected)
        }
        if point == "validation" {
            #expect(journal.values == ["validate", "validate"])
        } else {
            #expect(journal.values.filter { $0.hasPrefix("stop-") } == [
                "stop-second-b", "stop-second-a", "stop-first-b", "stop-first-a",
            ])
            #expect(journal.values.filter { $0.hasPrefix("release-") }.count == 4)
        }
        #expect(await weak.first == nil)
        #expect(await weak.second == nil)
    }

    @Test(arguments: [false, true])
    func `canceled construction awaits cleanup whether it throws or returns successfully`(factoryChecks: Bool)
        async throws
    {
        let journal = ResourceJournal()
        let construction = ResourceGate()
        let cleanup = ResourceGate()
        defer { construction.release(); cleanup.release() }
        let definition = ResourceDefinition(journal: journal, weak: ResourceWeakBox(),
                                            construction: construction, cleanup: cleanup,
                                            checkConstructionCancellation: factoryChecks)
        let startup = Task { try await startResource(definition) }
        await construction.waitForEntry()
        startup.cancel()
        construction.release()
        await cleanup.waitForEntry()
        #expect(!journal.values.contains("end-native-b"))
        cleanup.release()
        do {
            _ = try await startup.value
            Issue.record("Canceled startup published a resource")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.report.diagnostics.map(\.diagnostic.issue) == [.lifecycle(.startupCanceled)])
        }
        #expect(journal.values.filter { $0.hasPrefix("stop-") } == ["stop-native-b", "stop-native-a"])
        #expect(journal.values.filter { $0.hasPrefix("release-") }.count == 2)
    }

    @Test func `ordinary factory failure relies only on Swift object lifetime`() async throws {
        let journal = ResourceJournal()
        let system = try ScenarioSystem(named: "inert", definition: InertFailure(journal: journal))
        do {
            _ = try await ScenarioExecution.start(
                definition: ScenarioDefinition(attachments: [system.attachment]),
                scenarioID: .init(rawValue: "inert"), defaultMode: .record, systems: [AnyScenarioSystem(system)])
            Issue.record("Throwing factory returned")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.cleanup.isEmpty)
        }
        #expect(journal.values == ["ordinary-release"])
    }

    @Test @MainActor
    func `passthrough shutdown follows definition hooks and tolerates consumer stop`() async throws {
        let journal = ResourceJournal()
        let system = try ScenarioSystem(named: "live", definition: NativePassthrough(journal: journal))
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]),
            scenarioID: .init(rawValue: "live"), defaultMode: .passthrough, systems: [AnyScenarioSystem(system)])
        let native = try execution.dependency(system)
        native.stop()
        let final = await execution.finish()
        #expect(final.report.diagnostics.isEmpty)
        #expect(!native.inspect())
        #expect(journal.values.filter { $0 == "stop-live" }.count == 1)
        #expect(journal.values.contains("end-live"))
    }

    @Test func `later failure awaits passthrough cleanup before completing startup`() async throws {
        let journal = ResourceJournal()
        let cleanup = ResourceGate()
        defer { cleanup.release() }
        let live = try ScenarioSystem(named: "live", definition: NativePassthrough(journal: journal, cleanup: cleanup))
        let failing = try ScenarioSystem(named: "bad", definition: InertFailure(journal: journal))
        let startup = Task {
            try await ScenarioExecution.start(
                definition: ScenarioDefinition(attachments: [live.attachment, failing.attachment]),
                scenarioID: .init(rawValue: "abandon"), defaultMode: .record,
                systems: [AnyScenarioSystem(live.withMode(.passthrough)), AnyScenarioSystem(failing)])
        }
        await cleanup.waitForEntry()
        startup.cancel()
        #expect(!journal.values.contains("end-live"))
        cleanup.release()
        do {
            _ = try await startup.value
            Issue.record("Failed startup returned")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.cleanup.map(\.disposition) == [.completed])
        }
        #expect(journal.values.contains("end-live"))
        #expect(journal.values.contains("release-live"))
    }
}

private final class InertProbe: Sendable {
    let journal: ResourceJournal
    let message: String
    init(_ journal: ResourceJournal, _ message: String) {
        self.journal = journal; self.message = message
    }

    deinit { journal.append(message) }
}

private struct InertFailure: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.inert")
    let journal: ResourceJournal
    func makeRecordState(in _: borrowing SystemStateContext) throws {
        let object = InertProbe(journal, "ordinary-release")
        return try withExtendedLifetime(object) { throw ResourceTestFailure.expected }
    }

    func makeReplayState(in context: borrowing SystemStateContext) throws {
        try makeRecordState(in: context)
    }

    func makeRecordDependency(using _: SystemExecution<Void>) {}
    func makeReplayDependency(using _: SystemExecution<Void>) {}
    func makePassthroughDependency(using _: SystemExecution<Void>) {
        ()
    }
}

private struct NativePassthrough: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.passthrough-resource")
    let journal: ResourceJournal
    var cleanup: ResourceGate?
    func makeRecordState(in _: borrowing SystemStateContext) {
        ()
    }

    func makeReplayState(in _: borrowing SystemStateContext) {
        ()
    }

    func makeRecordDependency(using _: SystemExecution<Void>) throws -> ResourceNative {
        throw ResourceTestFailure.expected
    }

    func makeReplayDependency(using _: SystemExecution<Void>) throws -> ResourceNative {
        throw ResourceTestFailure.expected
    }

    @MainActor
    func makePassthroughDependency(using _: SystemExecution<Void>) -> ResourceNative {
        ResourceNative("live", journal: journal, cleanup: cleanup)
    }

    @MainActor
    func requestStopPassthrough(using _: borrowing SystemLifecycleContext<Void>, dependency: ResourceNative?) {
        dependency?.stop()
    }

    @MainActor
    func cleanUpPassthrough(using _: borrowing SystemLifecycleContext<Void>,
                            dependency: ResourceNative?) async -> SystemCleanupResult
    {
        #expect(!Task.isCancelled)
        return await dependency?.end() ?? .completed
    }
}
