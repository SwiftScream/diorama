@testable import DioramaCore
import Synchronization
import Testing

struct ScenarioStartupTests {
    @Test
    func `prepares all systems before ordered activation regardless of registration order`() async throws {
        let journal = ExecutionFixtures.Journal()

        let definition = try ExecutionFixtures.definition(["a", "b", "c"])
        let systems = try ["c", "a", "b"].map { try ExecutionFixtures.system($0, journal: journal) }
        let execution = try await ScenarioExecution.start(
            definition: definition,
            scenarioID: ScenarioID(rawValue: "execution"), defaultMode: .replay,
            systems: systems)
        #expect(journal.events.withLock { $0 } == [
            "prepare-a", "prepare-b", "prepare-c", "activate-a", "activate-b", "activate-c",
        ])
        let dependency = try execution.dependency(
            ExecutionFixtures.dependencyKey("a", as: HeaderlessSequentialTrackLease<Int>.self))
        #expect(dependency === journal.leases.withLock { $0[0] })
        #expect(!dependency.isClosed)
        let result = await execution.finish()
        #expect(journal.events.withLock { Array($0.suffix(3)) } == ["cleanup-c", "cleanup-b", "cleanup-a"])
        #expect(result.cleanup.map(\.attachmentID) == definition.attachments.map(\.id))
        #expect(result.cleanup.allSatisfy { $0.disposition == .completed })
        #expect(journal.leases.withLock { $0.allSatisfy(\.isClosed) })
    }

    @Test(arguments: [0, 1, 2])
    func `preparation failure activates nothing and closes every prepared lease`(failureIndex: Int) async throws {
        let journal = ExecutionFixtures.Journal()
        let keys = ["a", "b", "c"]
        let systems = try keys.enumerated().map { index, key in
            try ExecutionFixtures.system(
                key, journal: journal,
                failPreparation: index == failureIndex)
        }
        do {
            _ = try await ScenarioExecution.start(
                definition: ExecutionFixtures.definition(keys),
                scenarioID: ScenarioID(rawValue: "execution"), defaultMode: .replay,
                systems: systems)
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
    func `activation failure unwinds adapters despite cleanup failure`(failureIndex: Int) async throws {
        let journal = ExecutionFixtures.Journal()
        let keys = ["a", "b", "c"]
        let systems = try keys.enumerated().map { index, key in
            try ExecutionFixtures.system(
                key, journal: journal,
                failActivation: index == failureIndex, failCleanup: index == 1)
        }
        do {
            _ = try await ScenarioExecution.start(
                definition: ExecutionFixtures.definition(keys),
                scenarioID: ScenarioID(rawValue: "execution"), defaultMode: .replay,
                systems: systems)
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
    func `invalid registrations fail before any consumer callback`(kind: String) async throws {
        let journal = ExecutionFixtures.Journal()
        let system = try ExecutionFixtures.system("a", journal: journal)
        let other = try ExecutionFixtures.system("other", journal: journal)
        let systems = switch kind {
        case "missing": [AnyScenarioSystem]()
        case "duplicate": [system, system]
        case "extra": [system, other]
        default: [other]
        }

        let definition = try ExecutionFixtures.definition(["a"])
        do {
            _ = try await ScenarioExecution.start(
                definition: definition,
                scenarioID: ScenarioID(rawValue: "execution"), defaultMode: .replay,
                systems: systems)
            Issue.record("Invalid registrations must fail before preparation")
        } catch {
            #expect(error.report.diagnostics.map(\.diagnostic.issue) == [.lifecycle(.invalidRegistration)])
            #expect(error.cleanup.isEmpty)
        }
        #expect(journal.events.withLock { $0.isEmpty })
    }

    @Test
    func `unprepared tracks cannot slip through a successful system callback`() async throws {
        let activations = Mutex(0)

        let definition = try ExecutionFixtures.definition(["a"])
        let instance = try ScenarioSystem(type: ExecutionFixtures.type, attachment: definition.attachments[0]) { _ in
            PreparedSystem {
                activations.withLock { $0 += 1 }
                return ActivatedSystem(dependency: 0, deactivate: {})
            }
        }
        do {
            _ = try await ScenarioExecution.start(
                definition: definition,
                scenarioID: ScenarioID(rawValue: "execution"), defaultMode: .replay,
                systems: [AnyScenarioSystem(instance)])
            Issue.record("Unprepared tracks must reject startup")
        } catch {
            #expect(error.report.diagnostics.map(\.diagnostic.issue) == [
                .lifecycle(.preparationFailed), .lifecycle(.unpreparedTrack),
            ])
        }
        #expect(activations.withLock { $0 } == 0)
    }

    @Test(arguments: [true, false])
    func `validation retains one specific diagnostic before dependency construction`(pathSpecific: Bool) async throws {
        let activations = Mutex(0)
        let definition = try RejectingSystemDefinition(pathSpecific: pathSpecific, makeDependency: {
            activations.withLock { $0 += 1 }
        })
        let system = try ScenarioSystem(named: "validation", definition: definition)
        let baseline = try ScenarioDefinition(attachments: [system.attachment])
        let trackID = TrackID(attachmentID: system.attachment.id, key: definition.track.key)
        do {
            let execution = try await ScenarioExecution.start(
                definition: baseline,
                scenarioID: ScenarioID(rawValue: "validation"), defaultMode: .replay,
                systems: [AnyScenarioSystem(system)])
            _ = await execution.finish()
            Issue.record("Expected validation to reject startup")
        } catch {
            let facts = error.report.diagnostics.map(\.diagnostic)
            let validationIssue: DiagnosticIssue = pathSpecific ? .system(DiagnosticLabel("invalid-field"))
                : .preparationFailed(.validation)
            #expect(facts.map(\.issue) == [.lifecycle(.preparationFailed), validationIssue])
            let validation = try #require(facts.last)
            if pathSpecific {
                #expect(validation.context == .record(RecordIdentity(trackID: trackID, sequence: 0)))
                #expect(validation.fieldPath.map(\.text) == ["entries", "2", "value"])
            } else {
                #expect(validation.context == .track(trackID))
                #expect(validation.fieldPath.isEmpty)
            }
        }
        #expect(activations.withLock { $0 } == 0)
    }

    @Test(arguments: [ScenarioMode.record, .replay, .passthrough])
    func `startup validates prepared track values except in passthrough`(mode: ScenarioMode) async throws {
        let calls = Mutex<[Int]>([])

        let definitions = try ExecutionFixtures.definition(["a"])
        let instance = try ScenarioSystem(type: ExecutionFixtures.type,
                                          attachment: definitions.attachments[0])
        { context in
            if context.mode == .passthrough {
                return PreparedSystem { ActivatedSystem(dependency: 0, deactivate: {}) }
            }
            _ = try context.lease(
                for: ExecutionFixtures.track("a"),
                preparation: ValuePreparation<Int>(validate: { value in
                    calls.withLock { $0.append(value) }
                    throw ExecutionFixtures.SecretError(journal: ExecutionFixtures.Journal())
                }))
            return PreparedSystem { ActivatedSystem(dependency: 0, deactivate: {}) }
        }
        do {
            let execution = try await ScenarioExecution.start(
                definition: definitions, scenarioID: ScenarioID(rawValue: "execution"), defaultMode: mode,
                systems: [AnyScenarioSystem(instance)])
            #expect(mode == .passthrough)
            #expect(calls.withLock { $0.isEmpty })
            let result = await execution.finish()
            #expect(result.report.diagnostics.isEmpty)
        } catch {
            #expect(mode != .passthrough)
            #expect(calls.withLock { $0 } == [1])
            #expect(error.report.recordingHealth.isHealthy)
            #expect(error.report.diagnostics.contains { $0.diagnostic.issue == .preparationFailed(.validation) })
        }
    }
}

private struct RejectingSystemDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("validation")
    let track: TrackDefinition<Int, Void>
    let pathSpecific: Bool
    let makeDependency: @Sendable () -> Void

    init(pathSpecific: Bool, makeDependency: @escaping @Sendable () -> Void) throws {
        track = try TrackDefinition("values", values: [ValuePreparation<Int>().admitPrepared(1)])
        self.pathSpecific = pathSpecific
        self.makeDependency = makeDependency
    }

    var tracks: [AnyTrackDefinition] {
        [track.erased]
    }

    func validate(in context: borrowing SystemValidationContext) throws {
        if pathSpecific {
            try context.validate(track) { content in
                let record = try #require(content.records.first)
                throw FieldValidationError(record: record.identity)
            } diagnosticForFailure: { error in
                guard let error = error as? FieldValidationError else { return nil }
                return Diagnostic(issue: .system(DiagnosticLabel("invalid-field")),
                                  context: .record(error.record), fieldPath: [
                                      DiagnosticLabel("entries"), DiagnosticLabel(index: 2), DiagnosticLabel("value"),
                                  ])
            }
        } else {
            try context.validate(track) { _ in throw ScenarioLifecycleIssue.invalidTrackRequest }
        }
    }

    var record: SystemModeDefinition<Void, Void> {
        .init(makeDependency: makeDependency)
    }

    var replay: SystemModeDefinition<Void, Void> {
        record
    }

    var passthrough: SystemModeDefinition<Void, Void> {
        record
    }

    private struct FieldValidationError: Error {
        let record: RecordIdentity
    }
}
