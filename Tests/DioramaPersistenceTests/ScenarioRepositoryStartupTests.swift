import DioramaCore
import DioramaPersistence
import DioramaRandom
import Foundation
import Synchronization
import Testing

struct ScenarioRepositoryStartupTests {
    @Test
    func `loaded replay is authoritative and never reads or writes after startup`() async throws {
        let probe = StartupProbe()
        let system = try probe.system(key: "boundaries")
        let setup = try definition(mode: .replay, systems: [system])
        let storage = try StartupStorage(document: persistedFixture("random-boundaries"))
        let repository = try randomRepository(storage: storage)

        let started = try repository.start(
            configuredBy: setup,
            systems: [AnyScenarioSystem(system)])
        guard case let .loaded(baseline) = started.loadResult else {
            Issue.record("Expected the exact loaded result"); return
        }
        #expect(baseline.attachments.map(\.id.key.rawValue) == ["boundaries"])
        #expect(storage.readCount == 1)
        #expect(storage.writeCount == 0)
        #expect(probe.preparationCount == 1)
        #expect(probe.activationCount == 1)

        let lease = try started.execution.dependency(system)
        #expect(try lease.claimNext().value == 0)
        #expect(try lease.claimNext().value == UInt64.max)
        let result = await started.execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(storage.readCount == 1)
        #expect(storage.writeCount == 0)
    }

    @Test(arguments: ["missing", "unreadable", "invalid", "envelope", "system"])
    func `every unusable replay outcome refuses startup before system callbacks`(kind: String) throws {
        let probe = StartupProbe()
        let system = try probe.system(key: "boundaries")
        let setup = try definition(mode: .replay, systems: [system])
        let storage = try failureStorage(kind)
        let repository = try randomRepository(storage: storage)

        do {
            _ = try repository.start(
                configuredBy: setup,
                systems: [AnyScenarioSystem(system)])
            Issue.record("Unusable replay input returned an execution")
        } catch {
            let expected: ScenarioBaselineProblem = switch kind {
            case "missing": ScenarioBaselineProblem.missing
            case "unreadable": .unreadable
            case "invalid": .invalidDocument
            case "envelope": .incompatibleEnvelope
            default: .incompatibleSystem
            }
            #expect(error.startupFailure.report.diagnostics.map(\.diagnostic.issue) == [
                .baseline(.requiredBaselineUnavailable(expected)),
            ])
            guard case let .load(result) = error.evidence else {
                Issue.record("Expected retained load evidence"); return
            }
            #expect(loadProblem(result) == expected)
        }
        #expect(storage.readCount == 1)
        #expect(storage.writeCount == 0)
        #expect(probe.preparationCount == 0)
        #expect(probe.activationCount == 0)
    }

    @Test
    func `valid empty payload differs from missing replay attachment`() async throws {
        let emptyProbe = StartupProbe()
        let emptySystem = try emptyProbe.system(key: "empty")
        let emptySetup = try definition(mode: .replay, systems: [emptySystem])
        let emptyRepository = try randomRepository(
            storage: StartupStorage(document: persistedFixture("random-empty")))
        let started = try emptyRepository.start(
            configuredBy: emptySetup,
            systems: [AnyScenarioSystem(emptySystem)])
        let lease = try started.execution.dependency(emptySystem)
        #expect(throws: SequentialOperationFailure.self) {
            _ = try lease.claimNext()
        }
        #expect(emptyProbe.activationCount == 1)
        _ = await started.execution.finish()

        let missingProbe = StartupProbe()
        let missingSystem = try missingProbe.system(key: "other")
        let missingSetup = try definition(mode: .replay, systems: [missingSystem])
        do {
            _ = try emptyRepository.start(
                configuredBy: missingSetup,
                systems: [AnyScenarioSystem(missingSystem)])
            Issue.record("A valid document missing the replay attachment started")
        } catch {
            #expect(error.startupFailure.report.diagnostics.map(\.diagnostic.issue) == [
                .baseline(.replayAttachmentMissing),
            ])
            #expect(error.startupFailure.report.diagnostics.first?.diagnostic.context ==
                .attachment(missingSystem.attachment.id))
        }
        #expect(missingProbe.preparationCount == 0)
        #expect(missingProbe.activationCount == 0)
    }

    @Test(arguments: ["unreadable", "invalid", "envelope", "system"])
    func `record mode rebuilds from unusable input with nonfatal preservation evidence`(
        kind: String) async throws
    {
        let probe = StartupProbe()
        let system = try probe.system(key: "boundaries")
        let setup = try definition(mode: .record, systems: [system])
        let storage = try failureStorage(kind)
        let repository = try randomRepository(storage: storage)
        let started = try repository.start(
            configuredBy: setup,
            systems: [AnyScenarioSystem(system)])
        let expected: ScenarioBaselineProblem = switch kind {
        case "unreadable": ScenarioBaselineProblem.unreadable
        case "invalid": .invalidDocument
        case "envelope": .incompatibleEnvelope
        default: .incompatibleSystem
        }

        #expect(started.execution.reporter.report.diagnostics.map(\.diagnostic.issue) == [
            .baseline(.baselineIgnoredForRecording(expected)),
        ])
        #expect(started.execution.reporter.report.recordingHealth.isHealthy)
        #expect(probe.preparationCount == 1)
        #expect(probe.activationCount == 1)
        #expect(storage.writeCount == 0)
        let result = await started.execution.finish()
        #expect(result.report.recordingHealth.isHealthy)
        #expect(storage.writeCount == 0)
    }

    @Test
    func `missing is a normal first recording and passthrough does not require a baseline`() async throws {
        let recordingProbe = StartupProbe()
        let recording = try recordingProbe.system(key: "recording")
        let missingStorage = StartupStorage()
        let missing = try randomRepository(storage: missingStorage)
        let recordingStart = try missing.start(
            configuredBy: definition(mode: .record, systems: [recording]),
            systems: [AnyScenarioSystem(recording)])
        #expect(recordingStart.execution.reporter.report.diagnostics.isEmpty)
        #expect(recordingProbe.activationCount == 1)
        _ = await recordingStart.execution.finish()

        let passthroughProbe = StartupProbe()
        let passthrough = try passthroughProbe.system(key: "passthrough")
        let invalidStorage = StartupStorage(document: Data())
        let invalid = try randomRepository(storage: invalidStorage)
        let passthroughStart = try invalid.start(
            configuredBy: definition(mode: .passthrough, systems: [passthrough]),
            systems: [AnyScenarioSystem(passthrough)])
        #expect(passthroughStart.execution.reporter.report.diagnostics.isEmpty)
        #expect(passthroughProbe.activationCount == 1)
        _ = await passthroughStart.execution.finish()
        #expect(missingStorage.writeCount == 0)
        #expect(invalidStorage.writeCount == 0)
    }

    @Test
    func `one replay mode makes an unusable mixed baseline refuse every activation`() throws {
        let recordProbe = StartupProbe()
        let replayProbe = StartupProbe()
        let recording = try recordProbe.system(key: "recording", modeOverride: .record)
        let replaying = try replayProbe.system(key: "replaying", modeOverride: .replay)
        let setup = try definition(mode: .passthrough, systems: [recording, replaying])
        let storage = StartupStorage(document: Data())
        let repository = try randomRepository(storage: storage)

        #expect(throws: ScenarioRepositoryStartupFailure.self) {
            _ = try repository.start(
                configuredBy: setup,
                systems: [AnyScenarioSystem(recording), AnyScenarioSystem(replaying)])
        }
        #expect(recordProbe.preparationCount == 0)
        #expect(recordProbe.activationCount == 0)
        #expect(replayProbe.preparationCount == 0)
        #expect(replayProbe.activationCount == 0)
        #expect(storage.writeCount == 0)
    }

    @Test
    func `persistence registration fails before storage and ignored system callbacks`() throws {
        let probe = StartupProbe()
        let system = try probe.system(key: "ignored")
        let setup = try ScenarioDefinition(
            id: ScenarioID(rawValue: "registration"),
            defaultMode: .record,
            attachments: [system.attachment],
            ignoredAttachments: [system.attachment.id.key])
        let storage = try StartupStorage(document: persistedFixture("random-empty"))
        let repository = try JSONScenarioRepository(
            codec: JSONScenarioCodec(registry: PersistentSystemRegistry()),
            storage: storage)

        do {
            _ = try repository.start(
                configuredBy: setup,
                systems: [AnyScenarioSystem(system)])
            Issue.record("Unregistered ignored setup started")
        } catch {
            guard case let .persistenceConfiguration(dispatch) = error.evidence else {
                Issue.record("Expected registration evidence"); return
            }
            #expect(dispatch == .unknownSystemType(system.attachment.id.systemTypeID))
            #expect(error.startupFailure.report.diagnostics.map(\.diagnostic.issue) == [
                .baseline(.invalidPersistenceConfiguration),
            ])
        }
        #expect(storage.readCount == 0)
        #expect(storage.writeCount == 0)
        #expect(probe.preparationCount == 0)
        #expect(probe.activationCount == 0)
    }

    @Test
    func `loaded values receive current preparation policy before any activation`() throws {
        let probe = StartupProbe(failValidation: true)
        let system = try probe.system(key: "boundaries")
        let storage = try StartupStorage(document: persistedFixture("random-boundaries"))
        let repository = try randomRepository(storage: storage)
        let setup = try definition(mode: .replay, systems: [system])

        do {
            _ = try repository.start(
                configuredBy: setup,
                systems: [AnyScenarioSystem(system)])
            Issue.record("Current-policy validation failure returned an execution")
        } catch {
            guard case let .load(result) = error.evidence,
                  case .loaded = result
            else {
                Issue.record("Expected the exact loaded baseline"); return
            }
            #expect(error.startupFailure.report.diagnostics.contains {
                $0.diagnostic.issue == .preparationFailed(.validation)
            })
            #expect(error.startupFailure.report.diagnostics.contains {
                $0.diagnostic.issue == .lifecycle(.preparationFailed)
            })
        }
        #expect(probe.preparationCount == 1)
        #expect(probe.activationCount == 0)
        #expect(storage.writeCount == 0)
    }
}

struct UnmatchedAttachmentStartupTests {
    @Test
    func `loaded unmatched attachments are diagnosed and discarded before activation`() async throws {
        let probe = StartupProbe()
        let system = try probe.system(key: "account-id")
        let repository = try randomRepository(
            storage: StartupStorage(document: persistedFixture("random-example")))
        let started = try repository.start(
            configuredBy: definition(mode: .replay, systems: [system]),
            systems: [AnyScenarioSystem(system)])
        let lease = try started.execution.dependency(system)
        #expect(try lease.claimNext().value == 1842)
        let result = await started.execution.finish()

        guard case let .loaded(baseline) = started.loadResult else {
            Issue.record("Expected the exact loaded baseline"); return
        }
        #expect(baseline.attachments.map(\.id.key.rawValue) == ["account-id", "retry-jitter"])
        #expect(result.usage.map(\.attachmentID.key.rawValue) == ["account-id"])
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .baseline(.loadedAttachmentNotConfigured),
        ])
        #expect(result.report.diagnostics.map(\.diagnostic.context) == [
            .attachment(AttachmentID(
                systemTypeID: DioramaRandomSystem.systemTypeID,
                key: AttachmentKey(rawValue: "retry-jitter"))),
        ])
    }
}
