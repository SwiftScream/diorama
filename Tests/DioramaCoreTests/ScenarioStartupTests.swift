import DioramaCore
import Synchronization
import Testing

struct ScenarioStartupTests {
    @Test
    func `prepares all systems before ordered activation regardless of registration order`() async throws {
        let journal = ExecutionFixtures.Journal()
        let definition = try ExecutionFixtures.definition(["a", "b", "c"])
        let systems = ["c", "a", "b"].map { ExecutionFixtures.system($0, journal: journal) }
        let execution = try ScenarioExecution.start(definition: definition, systems: systems)
        #expect(journal.events.withLock { $0 } == [
            "prepare-a", "prepare-b", "prepare-c", "activate-a", "activate-b", "activate-c",
        ])
        let dependency = try execution.dependency(
            for: AttachmentKey(rawValue: "a"), as: SequentialTrackLease<Int>.self)
        #expect(dependency === journal.leases.withLock { $0[0] })
        #expect(!dependency.isClosed)
        let result = await execution.finish()
        #expect(journal.events.withLock { Array($0.suffix(3)) } == ["cleanup-c", "cleanup-b", "cleanup-a"])
        #expect(result.cleanup.map(\.attachmentID) == definition.attachments.map(\.id))
        #expect(result.cleanup.allSatisfy { $0.disposition == .completed })
        #expect(journal.leases.withLock { $0.allSatisfy(\.isClosed) })
    }

    @Test(arguments: [0, 1, 2])
    func `preparation failure activates nothing and closes every prepared lease`(failureIndex: Int) throws {
        let journal = ExecutionFixtures.Journal()
        let keys = ["a", "b", "c"]
        let systems = keys.enumerated().map { index, key in
            ExecutionFixtures.system(
                key, journal: journal,
                failPreparation: index == failureIndex)
        }
        do {
            _ = try ScenarioExecution.start(definition: ExecutionFixtures.definition(keys), systems: systems)
            Issue.record("A failed preparation must not return an execution")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.cleanup.isEmpty)
            #expect(failure.report.diagnostics.map(\.diagnostic.issue) == [.lifecycle(.preparationFailed)])
            #expect(failure.report.diagnostics.first?.diagnostic.context == .attachment(
                ExecutionFixtures.attachment(keys[failureIndex])))
            #expect(!String(reflecting: failure).contains("SECRET-LIFECYCLE-ERROR"))
        }
        #expect(journal.events.withLock { $0 } == keys.prefix(failureIndex + 1).map { "prepare-" + $0 })
        #expect(journal.leases.withLock { $0.count } == failureIndex + 1)
        #expect(journal.leases.withLock { $0.allSatisfy(\.isClosed) })
        #expect(journal.descriptions.withLock { $0 } == 0)
    }

    @Test(arguments: [0, 1, 2])
    func `activation failure unwinds adapters despite cleanup failure`(failureIndex: Int) throws {
        let journal = ExecutionFixtures.Journal()
        let keys = ["a", "b", "c"]
        let systems = keys.enumerated().map { index, key in
            ExecutionFixtures.system(
                key, journal: journal,
                failActivation: index == failureIndex, failCleanup: index == 1)
        }
        do {
            _ = try ScenarioExecution.start(definition: ExecutionFixtures.definition(keys), systems: systems)
            Issue.record("A failed activation must not return an execution")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.cleanup.map(\.attachmentID) == keys.prefix(failureIndex).map(ExecutionFixtures.attachment))
            #expect(failure.cleanup.map(\.disposition) == (0..<failureIndex).map { $0 == 1 ? .failed : .completed })
            #expect(failure.report.diagnostics.contains { $0.diagnostic.issue == .lifecycle(.activationFailed) })
            #expect(!String(reflecting: failure).contains("SECRET-LIFECYCLE-ERROR"))
        }
        let expected = keys.map { "prepare-" + $0 }
            + keys.prefix(failureIndex + 1).map { "activate-" + $0 }
            + keys.prefix(failureIndex).reversed().map { "cleanup-" + $0 }
        #expect(journal.events.withLock { $0 } == expected)
        #expect(journal.leases.withLock { $0.count == 3 && $0.allSatisfy(\.isClosed) })
        #expect(journal.descriptions.withLock { $0 } == 0)
    }

    @Test(arguments: ["missing", "duplicate", "extra", "incompatible"])
    func `invalid registrations fail before any consumer callback`(kind: String) throws {
        let journal = ExecutionFixtures.Journal()
        let system = ExecutionFixtures.system("a", journal: journal)
        let other = ExecutionFixtures.system("other", journal: journal)
        let systems = switch kind {
        case "missing": [ScenarioSystem]()
        case "duplicate": [system, system]
        case "extra": [system, other]
        default: [other]
        }
        let definition = try ExecutionFixtures.definition(["a"])
        do {
            _ = try ScenarioExecution.start(definition: definition, systems: systems)
            Issue.record("Invalid registrations must fail before preparation")
        } catch {
            #expect(error.report.diagnostics.map(\.diagnostic.issue) == [.lifecycle(.invalidRegistration)])
            #expect(error.cleanup.isEmpty)
        }
        #expect(journal.events.withLock { $0.isEmpty })
    }

    @Test
    func `unprepared tracks cannot slip through a successful system callback`() throws {
        let activations = Mutex(0)
        let definition = try ExecutionFixtures.definition(["a"])
        let system = ScenarioSystem(attachmentID: ExecutionFixtures.attachment("a")) { _ in
            PreparedSystem {
                activations.withLock { $0 += 1 }
                return SystemActivation(dependency: 0, deactivate: {})
            }
        }
        do {
            _ = try ScenarioExecution.start(definition: definition, systems: [system])
            Issue.record("Unprepared tracks must reject startup")
        } catch {
            #expect(error.report.diagnostics.map(\.diagnostic.issue) == [
                .lifecycle(.preparationFailed), .lifecycle(.unpreparedTrack),
            ])
        }
        #expect(activations.withLock { $0 } == 0)
    }

    @Test(arguments: [ScenarioMode.record, .replay, .passthrough])
    func `startup applies current track policy except in passthrough`(mode: ScenarioMode) async throws {
        let calls = Mutex<[Int]>([])
        let definitions = try ExecutionFixtures.definition(["a"], mode: mode)
        let system = ScenarioSystem(attachmentID: ExecutionFixtures.attachment("a")) { context in
            let lease = try context.lease(
                for: ExecutionFixtures.track("a"),
                preparation: ValuePreparation<Int>(validate: { value in
                    calls.withLock { $0.append(value) }
                    throw ExecutionFixtures.SecretError(journal: ExecutionFixtures.Journal())
                }))
            return PreparedSystem { SystemActivation(dependency: lease, deactivate: {}) }
        }
        do {
            let execution = try ScenarioExecution.start(definition: definitions, systems: [system])
            #expect(mode == .passthrough)
            #expect(calls.withLock { $0.isEmpty })
            let result = await execution.finish()
            #expect(result.report.diagnostics.isEmpty)
        } catch {
            #expect(mode != .passthrough)
            #expect(calls.withLock { $0 } == [1])
            #expect(error.report.recordingHealth.isHealthy == (mode != .record))
            #expect(error.report.diagnostics.contains { $0.diagnostic.issue == .preparationFailed(.validation) })
        }
    }
}
