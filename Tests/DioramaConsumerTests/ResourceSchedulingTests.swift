import DioramaCore
import Testing

struct ResourceSchedulingTests {
    @Test func `scheduler drainage waits until native stop releases its admitted callback`() async throws {
        let journal = ResourceJournal()
        let work = ResourceGate()
        defer { work.release() }
        let model = ResourceDefinition(journal: journal, weak: ResourceWeakBox(), work: work)
        let system = try ScenarioSystem(named: "native", definition: model)
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]),
            scenarioID: .init(rawValue: "scheduled-native"), defaultMode: .replay, systems: [AnyScenarioSystem(system)])
        let systemExecution = try execution.dependency(system)
        let identity = try RecordIdentity(trackID: #require(system.attachment.trackIDs.first), sequence: 0)
        try systemExecution.scheduling.schedule(after: .zero, for: identity) {
            do {
                try await systemExecution.state.withTrackedValue(\.second) { @MainActor native in
                    #expect(await native.callback() == false)
                    journal.append("delivery-drained")
                }
            } catch { Issue.record(error) }
        }
        await work.waitForEntry()
        let result = await execution.finish()
        #expect(journal.values.contains("delivery-drained"))
        #expect(result.report.diagnostics.isEmpty)
        let drained = try #require(journal.values.firstIndex(of: "delivery-drained"))
        let ended = try #require(journal.values.firstIndex(of: "end-native-b"))
        #expect(drained < ended)
    }

    @Test @MainActor
    func `record observation detachment permits an independent consumer owned forwarding tail`() async throws {
        let journal = ResourceJournal()
        let work = ResourceGate()
        defer { work.release() }
        let (execution, systemExecution) = try await startResource(
            ResourceDefinition(journal: journal, weak: ResourceWeakBox()))
        // The synthetic forwarding tail retains no systemExecution, resource, or recording lease.
        let forwarding = try systemExecution.state.withTrackedValue(\.first) { _ in
            Task {
                await work.suspend()
                journal.append("consumer-completed")
            }
        }
        await work.waitForEntry()
        let result = await execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(journal.values.contains("end-native-a"))
        #expect(!journal.values.contains("consumer-completed"))
        work.release()
        await forwarding.value
        #expect(journal.values.last == "consumer-completed")
        #expect(systemExecution.reporter.postFinishDiagnostics.isEmpty)
    }
}
