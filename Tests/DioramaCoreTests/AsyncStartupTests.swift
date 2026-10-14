@testable import DioramaCore
import Synchronization
import Testing

struct AsyncStartupTests {
    @Test func `cancellation before activation constructs nothing`() async throws {
        let journal = ExecutionFixtures.Journal()
        let definition = try ExecutionFixtures.definition(["a"])
        let system = try ExecutionFixtures.system("a", journal: journal)
        let startup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ScenarioExecution.start(
                definition: definition, scenarioID: .init(rawValue: "canceled"),
                defaultMode: .replay, systems: [system])
        }
        do {
            _ = try await startup.value
            Issue.record("Canceled startup returned an execution")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.report.diagnostics.map(\.diagnostic.issue) == [.lifecycle(.startupCanceled)])
            #expect(failure.cleanup.isEmpty)
        }
        #expect(journal.events.withLock { $0.isEmpty })
    }

    @Test func `successful activation hands cleanup to Core before cancellation check`() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let cleaned = Mutex(false)
        let id = ExecutionFixtures.attachment("a")
        let system = try ScenarioSystem(type: ExecutionFixtures.type, attachment: ScenarioAttachment(id: id)) { _ in
            PreparedSystem {
                entered.continuation.finish()
                // Continuations intentionally let configuration finish after cancellation.
                await withCheckedContinuation { continuation in
                    Task {
                        for await _ in resume.stream {}
                        continuation.resume()
                    }
                }
                return ActivatedSystem(dependency: 1) {
                    #expect(!Task.isCancelled)
                    cleaned.withLock { $0 = true }
                }
            }
        }
        let startup = Task {
            try await ScenarioExecution.start(
                definition: ScenarioDefinition(attachments: [system.attachment]),
                scenarioID: .init(rawValue: "handoff"), defaultMode: .record,
                systems: [AnyScenarioSystem(system)])
        }
        for await _ in entered.stream {}
        startup.cancel()
        #expect(!cleaned.withLock { $0 })
        resume.continuation.finish()
        do {
            _ = try await startup.value
            Issue.record("Canceled startup published its dependency")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.cleanup.map(\.disposition) == [.completed])
            #expect(failure.report.diagnostics.map(\.diagnostic.issue) == [.lifecycle(.startupCanceled)])
        }
        #expect(cleaned.withLock { $0 })
    }
}
