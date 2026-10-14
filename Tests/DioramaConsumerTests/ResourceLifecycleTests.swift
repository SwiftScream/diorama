import DioramaCore
import Testing

struct ResourceLifecycleTests {
    @Test(arguments: [ScenarioMode.record, .replay]) @MainActor
    func `actor resources support sync async and quiet access and release retained facades`(mode: ScenarioMode)
        async throws
    {
        let journal = ResourceJournal()
        let weak = ResourceWeakBox()
        let (execution, systemExecution) = try await startResource(
            ResourceDefinition(journal: journal, weak: weak), mode: mode)
        let stateAccess = systemExecution.state
        if case .ignored = try stateAccess.withLockIfOpen({ state, _ in state.observations += 1 }) {
            Issue.record("Published callback could not mutate state")
        }
        #expect(try stateAccess.withLock { state, _ in state.observations } == 1)
        #expect(try stateAccess.withTrackedValue(\.first) { $0.inspect() })
        #expect(try systemExecution.state.withTrackedValue(\.first) { $0.inspect() })
        #expect(try await stateAccess.withTrackedValue(\.first) { @MainActor in await $0.callback() })
        if case let .performed(value) = try systemExecution.state.withTrackedValueIfOpen(\.first, { $0.inspect() }) {
            #expect(value)
        } else {
            Issue.record("Published resource was closed")
        }
        let result = await execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.cleanup.map(\.disposition) == [.completed])
        #expect(weak.first == nil && weak.second == nil)
        #expect(journal.values.filter { $0.hasPrefix("stop-") } == ["stop-native-b", "stop-native-a"])
        #expect(journal.values.filter { $0.hasPrefix("end-") && !$0.hasPrefix("end-enter-") } == [
            "end-native-b", "end-native-a",
        ])
        if case .performed = try stateAccess.withTrackedValueIfOpen(\.first, { $0.inspect() }) {
            Issue.record("Closed callback entered")
        }
        if case .performed = try await systemExecution.state.withTrackedValueIfOpen(
            \.first, { @MainActor in await $0.callback() })
        {
            Issue.record("Closed async callback entered")
        }
        #expect(systemExecution.reporter.postFinishDiagnostics.isEmpty)
        #expect(throws: SequentialOperationFailure.self) { try stateAccess.withTrackedValue(\.first) { $0.inspect() } }
        #expect(systemExecution.reporter.postFinishDiagnostics.count == 1)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test @MainActor
    func `resource calls inside protected state reject before native invocation or nested lookup`() async throws {
        let journal = ResourceJournal()
        let (execution, systemExecution) = try await startResource(
            ResourceDefinition(journal: journal, weak: ResourceWeakBox()))
        try systemExecution.state.withLock { _, _ in
            #expect(throws: SequentialOperationFailure.self) {
                try systemExecution.state.withTrackedValue(\.first) { $0.stop() }
            }
            #expect(throws: SequentialOperationFailure.self) {
                try systemExecution.state.withTrackedValueIfOpen(\.first) { $0.stop() }
            }
        }
        #expect(!journal.values.contains { $0.hasPrefix("stop-") })
        let final = await execution.finish()
        let issues = final.report.diagnostics.map(\.diagnostic.issue)
        #expect(issues == Array(repeating: .lifecycle(.trackedValueInsideState), count: 2))
    }

    @Test
    func `stop releases held callback before drainage and finish awaits cleanup despite canceled waiters`()
        async throws
    {
        let journal = ResourceJournal()
        let work = ResourceGate()
        let cleanup = ResourceGate()
        let weak = ResourceWeakBox()
        defer { work.release(); cleanup.release() }
        let (execution, systemExecution) = try await startResource(
            ResourceDefinition(journal: journal, weak: weak, work: work, cleanup: cleanup))
        let callback = Task {
            let access = try await systemExecution.state.withTrackedValueIfOpen(\.second) { @MainActor native in
                #expect(await native.callback() == false)
                if case .performed = try systemExecution.state.withLockIfOpen({ state, _ in
                    state.observations += 1
                }) {
                    Issue.record("Resumed callback mutated closed state")
                }
            }
            if case .ignored = access {
                Issue.record("Published callback did not enter")
            }
        }
        await work.waitForEntry()
        let finishing = Task { await execution.finish() }
        await cleanup.waitForEntry()
        try await callback.value
        finishing.cancel()
        let another = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await execution.finish()
        }
        #expect(systemExecution.reporter.report == nil)
        #expect(!journal.values.contains("end-native-b"))
        cleanup.release()
        let result = await finishing.value
        let other = await another.value
        #expect(other.report == result.report)
        #expect(result.report.diagnostics.isEmpty)
        #expect(await weak.first == nil)
        #expect(await weak.second == nil)
        #expect(journal.values.filter { $0 == "stop-native-b" }.count == 1)
    }

    @Test @MainActor
    func `stop callback reentry is quiet and capture destruction occurs before report freeze`() async throws {
        let journal = ResourceJournal()
        let weak = ResourceWeakBox()
        let (execution, systemExecution) = try await startResource(ResourceDefinition(journal: journal, weak: weak))
        try systemExecution.state.withTrackedValue(\.first) { native in
            native.capture = ResourceReleaseWitness {
                systemExecution.reporter.record(Diagnostic(issue: .system(DiagnosticLabel("capture-released")),
                                                           recordingImpact: .invalidatesCandidate))
                _ = try? systemExecution.state.withLockIfOpen { _, _ in Issue.record("Release reopened state") }
            }
            native.stopCallback = {
                if case .performed = try? systemExecution.state.withTrackedValueIfOpen(\.second, { $0.inspect() }) {
                    Issue.record("Stop callback entered a closed resource")
                }
                systemExecution.reporter.record(Diagnostic(issue: .system(DiagnosticLabel("stop-reentry"))))
            }
        }
        let final = await execution.finish()
        #expect(final.report.diagnostics.map(\.diagnostic.issue) == [
            .system(DiagnosticLabel("stop-reentry")), .system(DiagnosticLabel("capture-released")),
        ])
        #expect(weak.first == nil && weak.second == nil)
        #expect(final.definition == nil)
    }

    @Test
    func `cleanup failure retains its label continues cleanup and leaves candidate healthy`() async throws {
        let journal = ResourceJournal()
        let definition = ResourceDefinition(journal: journal, weak: ResourceWeakBox(), failCleanup: true)
        let (execution, _) = try await startResource(definition)
        let final = await execution.finish()
        #expect(final.cleanup.map(\.disposition) == [.failed])
        #expect(final.report.diagnostics.map(\.diagnostic.issue) == [
            .system(DiagnosticLabel("resource-cleanup-failed")), .lifecycle(.cleanupFailed),
        ])
        #expect(final.definition != nil)
        #expect(journal.values.contains("end-native-a"))
    }
}
