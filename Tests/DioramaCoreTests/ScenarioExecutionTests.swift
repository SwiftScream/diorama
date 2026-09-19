import DioramaCore
import Synchronization
import Testing

struct ScenarioExecutionTests {
    @Test
    func `two starts have independent leases reporters and finish state`() async throws {
        let journal = ExecutionFixtures.Journal()
        let definitionConfiguration = ScenarioConfiguration(id: ScenarioID(rawValue: "execution"), defaultMode: .replay)
        let definition = try ExecutionFixtures.definition(["a"])
        let systems = [ExecutionFixtures.system("a", journal: journal)]
        let first = try ScenarioExecution.start(
            definition: definition,
            configuration: definitionConfiguration,
            systems: systems)
        let second = try ScenarioExecution.start(
            definition: definition,
            configuration: definitionConfiguration,
            systems: systems)
        let key = ExecutionFixtures.dependencyKey("a", as: SequentialTrackLease<Int>.self)
        let firstLease = try first.dependency(key)
        let secondLease = try second.dependency(key)
        #expect(firstLease !== secondLease)
        #expect(first.reporter !== second.reporter)
        #expect(firstLease.report(.system(DiagnosticLabel("first-only"))))
        let result = await first.finish()
        #expect(result.report.diagnostics.count == 1)
        #expect(firstLease.isClosed)
        #expect(!secondLease.isClosed)
        #expect(second.reporter.report.diagnostics.isEmpty)
        let secondResult = await second.finish()
        #expect(secondResult.report.diagnostics.isEmpty)
        #expect(journal.events.withLock { $0.filter { $0 == "cleanup-a" }.count } == 2)
    }

    @Test
    func `heterogeneous dependencies inherit whole attachment modes`() async throws {
        let first = ExecutionFixtures.attachment("first")
        let second = AttachmentID(systemTypeID: SystemTypeID(rawValue: "text"), key: AttachmentKey(rawValue: "second"))
        let definitionConfiguration = ScenarioConfiguration(
            id: ScenarioID(rawValue: "heterogeneous"),
            defaultMode: .record,
            modeOverrides: [second.key: .passthrough])
        let definition = try ScenarioDefinition(attachments: [
            ScenarioAttachment(id: first),
            ScenarioAttachment(id: second),
        ])
        let firstInstance = ScenarioSystem(attachment: ScenarioAttachment(id: first)) { context in
            #expect(context.mode == .record)
            return PreparedSystem { ActivatedSystem(dependency: 42, deactivate: {}) }
        }
        let secondInstance = ScenarioSystem(attachment: ScenarioAttachment(id: second)) { context in
            #expect(context.mode == .passthrough)
            return PreparedSystem { ActivatedSystem(dependency: "text", deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: definition, configuration: definitionConfiguration,
            systems: [AnyScenarioSystem(firstInstance), AnyScenarioSystem(secondInstance)])
        #expect(try execution.dependency(firstInstance) == 42)
        #expect(try execution.dependency(secondInstance.dependencyKey) == "text")
        let wrongType = DependencyKey<String>(attachmentID: first)
        #expect(throws: DependencyAccessFailure.self) { try execution.dependency(wrongType) }
        let wrongSystem = DependencyKey<Int>(attachmentID: AttachmentID(
            systemTypeID: second.systemTypeID,
            key: first.key))
        #expect(throws: DependencyAccessFailure.self) { try execution.dependency(wrongSystem) }
        let missing = DependencyKey<Int>(
            attachmentID: ExecutionFixtures.attachment("missing"))
        #expect(throws: DependencyAccessFailure.self) {
            try execution.dependency(missing)
        }
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.invalidDependencyRequest),
            .lifecycle(.invalidDependencyRequest),
            .lifecycle(.invalidDependencyRequest),
        ])
        #expect(result.report.diagnostics.map(\.diagnostic.context) == [
            .attachment(first),
            .attachment(missing.attachmentID),
            .attachment(wrongSystem.attachmentID),
        ])
    }

    @Test(arguments: [false, true])
    func `finish freezes results and closed lease use stays in separately retained log`(hasSink: Bool) async throws {
        let notifications = Mutex<[DiagnosticIssue]>([])
        let journal = ExecutionFixtures.Journal()
        let sink = DiagnosticSink { entry in notifications.withLock { $0.append(entry.diagnostic.issue) } }
        let execution = try ScenarioExecution.start(
            definition: ExecutionFixtures.definition(["a"]), configuration: ScenarioConfiguration(
                id: ScenarioID(rawValue: "execution"),
                defaultMode: .replay),
            systems: [ExecutionFixtures.system("a", journal: journal)], sink: hasSink ? sink : nil)
        let key = ExecutionFixtures.dependencyKey("a", as: SequentialTrackLease<Int>.self)
        let lease = try execution.dependency(key)
        #expect(lease.report(.system(DiagnosticLabel("before"))))
        let result = await execution.finish()
        #expect(!lease.report(.system(DiagnosticLabel("discarded")), recordingImpact: .invalidatesCandidate))
        #expect(throws: DependencyAccessFailure.self) {
            try execution.dependency(key)
        }
        #expect(await execution.finish() == result)
        #expect(execution.reporter.report == result.report)
        #expect(result.report.recordingHealth.isHealthy)
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.executionClosed), .lifecycle(.leaseClosed),
        ])
        #expect(notifications.withLock { $0.count } == (hasSink ? 3 : 0))
        #expect(journal.events.withLock { $0.filter { $0 == "cleanup-a" }.count } == 1)
    }

    @Test
    func `cleanup failures preserve reverse cleanup and one result for concurrent canceled callers`() async throws {
        let journal = ExecutionFixtures.Journal()
        let execution = try ScenarioExecution.start(
            definition: ExecutionFixtures.definition(["a", "b", "c"]), configuration: ScenarioConfiguration(
                id: ScenarioID(rawValue: "execution"),
                defaultMode: .replay),
            systems: ["a", "b", "c"].map {
                ExecutionFixtures.system(
                    $0, journal: journal, failCleanup: $0 == "b")
            })
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await execution.finish()
        }
        let results = await withTaskGroup(
            of: ScenarioFinalizationResult.self, returning: [ScenarioFinalizationResult].self)
        { group in
            for _ in 0..<12 {
                group.addTask { await execution.finish() }
            }
            var results: [ScenarioFinalizationResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        let result = await canceled.value
        #expect(results.count == 12)
        #expect(results.allSatisfy { $0 == result })
        #expect(result.cleanup.map(\.disposition) == [.completed, .failed, .completed])
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.lifecycle(.cleanupFailed)])
        #expect(journal.events.withLock { $0.filter { $0.hasPrefix("cleanup-") } } == [
            "cleanup-c", "cleanup-b", "cleanup-a",
        ])
        #expect(journal.descriptions.withLock { $0 } == 0)
        #expect(!String(reflecting: result).contains("SECRET-LIFECYCLE-ERROR"))
    }

    @Test
    func `leases close before cleanup and callbacks can reenter diagnostics and lookup`() async throws {
        let executionReference = Mutex<ScenarioExecution?>(nil)
        defer { executionReference.withLock { $0 = nil } }
        let definitionConfiguration = ScenarioConfiguration(id: ScenarioID(rawValue: "execution"), defaultMode: .replay)
        let definition = try ExecutionFixtures.definition(["a"])
        let instance = ScenarioSystem(
            attachment: ScenarioAttachment(id: ExecutionFixtures.attachment("a")))
        { context in
            let lease = try context.lease(for: ExecutionFixtures.track("a"), preparation: ValuePreparation<Int>())
            return PreparedSystem {
                ActivatedSystem(dependency: lease) {
                    #expect(lease.isClosed)
                    #expect(!lease.report(.system(DiagnosticLabel("cleanup-use"))))
                    let execution = try #require(executionReference.withLock { $0 })
                    #expect(throws: DependencyAccessFailure.self) {
                        try execution.dependency(ExecutionFixtures.dependencyKey(
                            "a", as: SequentialTrackLease<Int>.self))
                    }
                }
            }
        }
        let execution = try ScenarioExecution.start(
            definition: definition, configuration: definitionConfiguration, systems: [AnyScenarioSystem(instance)],
            sink: DiagnosticSink { _ in
                let execution = try #require(executionReference.withLock { $0 })
                #expect(!execution.reporter.report.diagnostics.isEmpty)
            })
        executionReference.withLock { $0 = execution }
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.executionClosed), .lifecycle(.leaseClosed),
        ])
    }

    @Test
    func `empty execution still has explicit idempotent finish`() async throws {
        let definitionConfiguration = ScenarioConfiguration(id: ScenarioID(rawValue: "empty"), defaultMode: .record)
        let definition = try ScenarioDefinition()
        let execution = try ScenarioExecution.start(
            definition: definition,
            configuration: definitionConfiguration,
            systems: [])
        let result = await execution.finish()
        #expect(result.cleanup.isEmpty)
        #expect(result.report.diagnostics.isEmpty)
        #expect(await execution.finish() == result)
    }
}
