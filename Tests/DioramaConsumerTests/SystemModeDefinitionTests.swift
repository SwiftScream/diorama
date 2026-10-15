import DioramaCore
import Synchronization
import Testing

struct SystemModeDefinitionTests {
    @Test(arguments: [ScenarioMode.record, .replay, .passthrough])
    func `selected declarations follow validation and bind fresh state and hooks for each run`(mode: ScenarioMode)
        async throws
    {
        let journal = ResourceJournal()
        let first = try ScenarioSystem(named: "first", definition: ModeProbeDefinition(name: "first", journal: journal))
        let second = try ScenarioSystem(
            named: "second", definition: ModeProbeDefinition(name: "second", journal: journal))
        #expect(journal.values.isEmpty)
        for generation in 1...2 {
            let execution = try await ScenarioExecution.start(
                definition: ScenarioDefinition(attachments: [first.attachment, second.attachment]),
                scenarioID: .init(rawValue: "modes"), defaultMode: mode,
                systems: [AnyScenarioSystem(first), AnyScenarioSystem(second)])
            let firstState = try execution.dependency(first)
            #expect(try firstState.state.withLock { state, _ in
                let initial = state
                state = -1
                return initial
            } == generation)
            #expect(try execution.dependency(second).state.withLock { state, _ in state } == generation)
            let prefix = "\(mode)-\(generation)-"
            #expect(Array(journal.values.suffix(10)) == [
                "validate-first", "validate-second",
                prefix + "declare-first", prefix + "state-first", prefix + "dependency-first", prefix + "release-first",
                prefix + "declare-second", prefix + "state-second",
                prefix + "dependency-second", prefix + "release-second",
            ])
            let result = await execution.finish()
            #expect(Array(journal.values.suffix(4)) == [
                prefix + "stop-second", prefix + "stop-first", prefix + "cleanup-second", prefix + "cleanup-first",
            ])
            #expect(result.cleanup.map(\.disposition) == [.completed, .completed])
            #expect(result.report.diagnostics.isEmpty)
        }
    }

    @Test(arguments: [ScenarioMode.record, .replay, .passthrough], [false, true])
    func `void state conveniences retain actor isolated hooks and successful nil dependencies`(
        mode: ScenarioMode, needsExecution: Bool) async throws
    {
        let journal = ResourceJournal()
        let system = try ScenarioSystem(named: "void", definition: VoidModeDefinition(
            journal: journal, needsExecution: needsExecution))
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]), scenarioID: .init(rawValue: "void"),
            defaultMode: mode, systems: [AnyScenarioSystem(system)])
        #expect(try execution.dependency(system) == nil)
        let result = await execution.finish()
        #expect(journal.values == ["dependency", "stop", "cleanup"])
        #expect(result.cleanup.map(\.disposition) == [.completed])
        #expect(result.report.diagnostics.isEmpty)
    }
}

private final class ModeProbeDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.mode-probe")
    let name: String
    let journal: ResourceJournal
    private let generation = Mutex(0)

    init(name: String, journal: ResourceJournal) {
        self.name = name
        self.journal = journal
    }

    func validate(in _: borrowing SystemValidationContext) {
        journal.append("validate-" + name)
    }

    var record: SystemModeDefinition<Int, SystemExecution<Int>> {
        declaration(for: .record)
    }

    var replay: SystemModeDefinition<Int, SystemExecution<Int>> {
        declaration(for: .replay)
    }

    var passthrough: SystemModeDefinition<Int, SystemExecution<Int>> {
        declaration(for: .passthrough)
    }

    private func declaration(for mode: ScenarioMode) -> SystemModeDefinition<Int, SystemExecution<Int>> {
        let journal = journal
        let name = name
        let number = generation.withLock { $0 += 1; return $0 }
        let prefix = "\(mode)-\(number)-"
        journal.append(prefix + "declare-" + name)
        let capture = ResourceReleaseWitness { journal.append(prefix + "release-" + name) }
        return .init(makeState: { _ in
            withExtendedLifetime(capture) {}
            journal.append(prefix + "state-" + name)
            return number
        }, makeDependency: { execution in
            journal.append(prefix + "dependency-" + name)
            return execution
        }, requestStop: { _, _ in journal.append(prefix + "stop-" + name) }, cleanUp: { _, _ in
            journal.append(prefix + "cleanup-" + name)
            return .completed
        })
    }
}

private struct VoidModeDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.void-mode")
    let journal: ResourceJournal
    let needsExecution: Bool

    var record: SystemModeDefinition<Void, Int?> {
        if needsExecution {
            .init(makeDependency: { @MainActor execution in
                _ = try execution.state.withLock { _, _ in () }
                return makeDependency()
            }, requestStop: stop, cleanUp: cleanup)
        } else {
            .init(makeDependency: makeDependency, requestStop: stop, cleanUp: cleanup)
        }
    }

    var replay: SystemModeDefinition<Void, Int?> {
        record
    }

    var passthrough: SystemModeDefinition<Void, Int?> {
        record
    }

    @MainActor private func makeDependency() -> Int? {
        MainActor.assertIsolated()
        journal.append("dependency")
        return nil
    }

    @MainActor private func stop(_: borrowing SystemLifecycleContext<Void>, dependency: Int??) {
        MainActor.assertIsolated()
        if case .some(.none) = dependency {} else {
            Issue.record("Returned nil must retain the ownership optional")
        }
        journal.append("stop")
    }

    @MainActor private func cleanup(_: borrowing SystemLifecycleContext<Void>, dependency: Int??) async
        -> SystemCleanupResult
    {
        MainActor.assertIsolated()
        await Task.yield()
        if case .some(.none) = dependency {} else {
            Issue.record("Cleanup must receive the returned nil")
        }
        journal.append("cleanup")
        return .completed
    }
}
