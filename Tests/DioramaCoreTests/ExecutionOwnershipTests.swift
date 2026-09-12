import DioramaCore
import Synchronization
import Testing

struct ExecutionOwnershipTests {
    private final class Observations: Sendable {
        let releases = Mutex<[String]>([])
        let context = Mutex<SystemPreparationContext?>(nil)
    }

    @Test
    func `finish releases sources and content despite escaped leases contexts and reporter`() async throws {
        let observations = Observations()
        var execution: ScenarioExecution? = try makeOwnedExecution(observations)
        weak let weakExecution = execution
        var lease: SequentialTrackLease<ExecutionFixtures.Probe>? = try execution?.dependency(
            for: AttachmentKey(rawValue: "a"), as: SequentialTrackLease<ExecutionFixtures.Probe>.self)
        var reporter: DiagnosticReporter? = execution?.reporter
        weak let weakReporter = reporter
        #expect(observations.releases.withLock { $0 } == ["recipe"])
        let result = try #require(await execution?.finish())
        #expect(observations.releases.withLock { $0.sorted() } == ["content", "recipe", "source"])
        #expect(lease?.isClosed == true)
        execution = nil
        #expect(weakExecution == nil)

        #expect(lease?.report(.system(DiagnosticLabel("escaped"))) == false)
        #expect(reporter?.report == result.report)
        #expect(reporter?.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
        let context = try #require(observations.context.withLock { $0 })
        #expect(throws: PreparationFailure.self) {
            try context.lease(
                for: ExecutionFixtures.track("a"), preparation: ValuePreparation<ExecutionFixtures.Probe>())
        }
        observations.context.withLock { $0 = nil }
        lease = nil
        reporter = nil
        // The deliberately escaped context is also a lightweight reporter owner.
        #expect(weakReporter != nil)
        withExtendedLifetime(context) {}
    }

    @Test
    func `reporter dies when execution leases and escaped contexts release it`() async throws {
        weak var weakReporter: DiagnosticReporter?
        let result: ScenarioFinalizationResult
        do {
            let observations = Observations()
            let execution = try makeOwnedExecution(observations)
            weakReporter = execution.reporter
            result = await execution.finish()
            observations.context.withLock { $0 = nil }
        }
        #expect(weakReporter == nil)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test(arguments: [false, true])
    func `resource destruction diagnostics precede result freeze`(failStartup: Bool) async throws {
        let first = ExecutionFixtures.attachment("a")
        let second = ExecutionFixtures.attachment("b")
        let definition = try ScenarioDefinition(
            id: ScenarioID(rawValue: "release-diagnostics"), defaultMode: .passthrough,
            attachments: [ScenarioAttachment(id: first), ScenarioAttachment(id: second)])
        let system = ScenarioSystem(attachmentID: first) { context in
            PreparedSystem {
                let source = ExecutionFixtures.Probe {
                    context.reporter.record(Diagnostic(issue: .system(DiagnosticLabel("resource-released"))))
                }
                return SystemActivation(dependency: 0) { withExtendedLifetime(source) {} }
            }
        }
        let other = ScenarioSystem(attachmentID: second) { _ in
            PreparedSystem {
                if failStartup {
                    throw ExecutionFixtures.SecretError(journal: ExecutionFixtures.Journal())
                }
                return SystemActivation(dependency: 0, deactivate: {})
            }
        }
        do {
            let execution = try ScenarioExecution.start(definition: definition, systems: [system, other])
            #expect(!failStartup)
            let result = await execution.finish()
            #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
                .system(DiagnosticLabel("resource-released")),
            ])
            #expect(execution.reporter.postFinishDiagnostics.isEmpty)
        } catch {
            #expect(failStartup)
            #expect(error.report.diagnostics.map(\.diagnostic.issue) == [
                .system(DiagnosticLabel("resource-released")), .lifecycle(.activationFailed),
            ])
        }
    }

    @Test
    func `consumer source remains consumer owned after adapter cleanup`() async throws {
        let releases = Mutex(0)
        var source: ExecutionFixtures.Probe? = ExecutionFixtures.Probe { releases.withLock { $0 += 1 } }
        let definition = try ScenarioDefinition(
            id: ScenarioID(rawValue: "consumer-owned"), defaultMode: .passthrough,
            attachments: [ScenarioAttachment(id: ExecutionFixtures.attachment("a"))])
        let execution: ScenarioExecution
        do {
            let retainedSource = try #require(source)
            let system = ScenarioSystem(attachmentID: ExecutionFixtures.attachment("a")) { _ in
                PreparedSystem {
                    SystemActivation(dependency: 0) { withExtendedLifetime(retainedSource) {} }
                }
            }
            execution = try ScenarioExecution.start(definition: definition, systems: [system])
        }
        let result = await execution.finish()
        #expect(result.cleanup.map(\.disposition) == [.completed])
        #expect(releases.withLock { $0 } == 0)
        source = nil
        #expect(releases.withLock { $0 } == 1)
    }

    @Test
    func `preparation context rejects repeated incompatible missing and escaped requests`() async throws {
        let contexts = Mutex<SystemPreparationContext?>(nil)
        let definition = try ExecutionFixtures.definition(["a"])
        let system = ScenarioSystem(attachmentID: ExecutionFixtures.attachment("a")) { context in
            contexts.withLock { $0 = context }
            #expect(throws: PreparationFailure.self) {
                try context.lease(for: ExecutionFixtures.track("a"), preparation: ValuePreparation<String>())
            }
            #expect(throws: PreparationFailure.self) {
                try context.lease(for: ExecutionFixtures.track("missing"), preparation: ValuePreparation<Int>())
            }
            let lease = try context.lease(for: ExecutionFixtures.track("a"), preparation: ValuePreparation<Int>())
            #expect(throws: PreparationFailure.self) {
                try context.lease(for: ExecutionFixtures.track("a"), preparation: ValuePreparation<Int>())
            }
            return PreparedSystem { SystemActivation(dependency: lease, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(definition: definition, systems: [system])
        let context = try #require(contexts.withLock { $0 })
        #expect(throws: PreparationFailure.self) {
            try context.lease(for: ExecutionFixtures.track("a"), preparation: ValuePreparation<Int>())
        }
        let result = await execution.finish()
        #expect(result.report.diagnostics.filter { $0.diagnostic.issue == .lifecycle(.invalidTrackRequest) }.count == 3)
        #expect(result.report.diagnostics.filter { $0.diagnostic.issue == .lifecycle(.preparationClosed) }.count == 1)
    }

    @Test
    func `rollback releases activation resources and content while escaped leases stay closed`() throws {
        let observations = Observations()
        let leases = Mutex<[SequentialTrackLease<ExecutionFixtures.Probe>]>([])
        let failure: ScenarioStartupFailure
        do {
            let content = ExecutionFixtures.Probe { observations.releases.withLock { $0.append("content") } }
            let attachment = try ScenarioAttachment(id: ExecutionFixtures.attachment("a")).adding(
                SequentialTrack(id: ExecutionFixtures.track("a"), values: preparedValues([content])))
            let definition = try ScenarioDefinition(
                id: ScenarioID(rawValue: "rollback"), defaultMode: .replay,
                attachments: [attachment, ScenarioAttachment(id: ExecutionFixtures.attachment("b"))])
            let first = ScenarioSystem(attachmentID: attachment.id) { context in
                observations.context.withLock { $0 = context }
                let lease = try context.lease(
                    for: ExecutionFixtures.track("a"), preparation: ValuePreparation<ExecutionFixtures.Probe>())
                leases.withLock { $0.append(lease) }
                return PreparedSystem {
                    let source = ExecutionFixtures.Probe { observations.releases.withLock { $0.append("source") } }
                    return SystemActivation(dependency: lease) { withExtendedLifetime(source) {} }
                }
            }
            let second = ScenarioSystem(attachmentID: ExecutionFixtures.attachment("b")) { _ in
                PreparedSystem<Int> { throw ExecutionFixtures.SecretError(journal: ExecutionFixtures.Journal()) }
            }
            do {
                _ = try ScenarioExecution.start(definition: definition, systems: [first, second])
                Issue.record("The second activation must fail")
                return
            } catch { failure = error }
        }
        #expect(observations.releases.withLock { $0.sorted() } == ["content", "source"])
        #expect(leases.withLock { $0.count == 1 && $0.allSatisfy(\.isClosed) })
        let lease = try #require(leases.withLock { $0.first })
        #expect(!lease.report(.system(DiagnosticLabel("after-rollback"))))
        #expect(lease.reporter.report == failure.report)
        #expect(lease.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
    }

    private func makeOwnedExecution(_ observations: Observations) throws -> ScenarioExecution {
        let content = ExecutionFixtures.Probe { observations.releases.withLock { $0.append("content") } }
        let attachment = try ScenarioAttachment(id: ExecutionFixtures.attachment("a")).adding(
            SequentialTrack(id: ExecutionFixtures.track("a"), values: preparedValues([content])))
        let definition = try ScenarioDefinition(
            id: ScenarioID(rawValue: "owned"), defaultMode: .replay, attachments: [attachment])
        let system = ScenarioSystem(attachmentID: attachment.id) { context in
            observations.context.withLock { $0 = context }
            let lease = try context.lease(
                for: ExecutionFixtures.track("a"), preparation: ValuePreparation<ExecutionFixtures.Probe>())
            let recipe = ExecutionFixtures.Probe { observations.releases.withLock { $0.append("recipe") } }
            return PreparedSystem {
                withExtendedLifetime(recipe) {}
                let source = ExecutionFixtures.Probe { observations.releases.withLock { $0.append("source") } }
                return SystemActivation(dependency: lease) { withExtendedLifetime(source) {} }
            }
        }
        return try ScenarioExecution.start(definition: definition, systems: [system])
    }
}
