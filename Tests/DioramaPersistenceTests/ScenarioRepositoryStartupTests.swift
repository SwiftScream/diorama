import Diorama
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

        let storage = try StartupStorage(document: persistedFixture("random-boundaries"))
        let repository = try randomRepository(storage: storage)

        let result = try await Diorama(repository: repository,
                                       scenarioID: "repository-startup", mode: .replay,
                                       systems: system).execute { lease in
            #expect(storage.readCount == 1)
            #expect(storage.writeCount == 0)
            #expect(probe.preparationCount == 1)
            #expect(probe.activationCount == 1)
            return try [lease.claimNext().value, lease.claimNext().value]
        }
        guard case let .loaded(baseline, _) = result.loadResult else {
            Issue.record("Expected the exact loaded result"); return
        }
        #expect(baseline.attachments.map(\.id.key.rawValue) == ["boundaries"])
        #expect(result.body == [0, UInt64.max])
        #expect(result.finalization.report.diagnostics.isEmpty)
        #expect(storage.readCount == 1)
        #expect(storage.writeCount == 0)
    }

    @Test(arguments: ["missing", "unreadable", "invalid", "envelope", "system"])
    func `every unusable replay outcome refuses startup before system callbacks`(kind: String) async throws {
        let probe = StartupProbe()
        let system = try probe.system(key: "boundaries")

        let storage = try failureStorage(kind)
        let repository = try randomRepository(storage: storage)

        do {
            _ = try await Diorama(repository: repository,
                                  scenarioID: "repository-startup", mode: .replay,
                                  systems: system).execute { _ in () }
            Issue.record("Unusable replay input returned an execution")
        } catch let error as ScenarioRepositoryStartupFailure {
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

        let emptyRepository = try randomRepository(
            storage: StartupStorage(document: persistedFixture("random-empty")))
        _ = try await Diorama(repository: emptyRepository,
                              scenarioID: "repository-startup", mode: .replay,
                              systems: emptySystem).execute { lease in
            #expect(throws: SequentialOperationFailure.self) { _ = try lease.claimNext() }
        }
        #expect(emptyProbe.activationCount == 1)

        let missingProbe = StartupProbe()
        let missingSystem = try missingProbe.system(key: "other")

        do {
            _ = try await Diorama(repository: emptyRepository,
                                  scenarioID: "repository-startup", mode: .replay,
                                  systems: missingSystem).execute { _ in () }
            Issue.record("A valid document missing the replay attachment started")
        } catch let error as ScenarioRepositoryStartupFailure {
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

        let storage = try failureStorage(kind)
        let repository = try randomRepository(storage: storage)
        let result = try await Diorama(repository: repository,
                                       scenarioID: "repository-startup", mode: .record,
                                       systems: system).execute { _ in
            #expect(probe.preparationCount == 1)
            #expect(probe.activationCount == 1)
            #expect(storage.writeCount == 0)
        }
        let expected: ScenarioBaselineProblem = switch kind {
        case "unreadable": ScenarioBaselineProblem.unreadable
        case "invalid": .invalidDocument
        case "envelope": .incompatibleEnvelope
        default: .incompatibleSystem
        }

        #expect(result.finalization.report.diagnostics.map(\.diagnostic.issue) == [
            .baseline(.baselineIgnoredForRecording(expected)),
        ])
        #expect(result.finalization.report.recordingHealth.isHealthy)
        #expect(storage.writeCount == 0)
    }

    @Test
    func `missing is a normal first recording and passthrough does not require a baseline`() async throws {
        let recordingProbe = StartupProbe()
        let recording = try recordingProbe.system(key: "recording")
        let missingStorage = StartupStorage()
        let missing = try randomRepository(storage: missingStorage)
        let recordingResult = try await Diorama(repository: missing,
                                                scenarioID: "repository-startup", mode: .record,
                                                systems: recording).execute { _ in () }
        #expect(recordingResult.finalization.report.diagnostics.isEmpty)
        #expect(recordingProbe.activationCount == 1)

        let passthroughProbe = StartupProbe()
        let passthrough = try passthroughProbe.system(key: "passthrough")
        let invalidStorage = StartupStorage(document: Data())
        let invalid = try randomRepository(storage: invalidStorage)
        let passthroughResult = try await Diorama(repository: invalid,
                                                  scenarioID: "repository-startup", mode: .passthrough,
                                                  systems: passthrough).execute { _ in () }
        #expect(passthroughResult.finalization.report.diagnostics.isEmpty)
        #expect(passthroughProbe.activationCount == 1)
        #expect(missingStorage.writeCount == 0)
        #expect(invalidStorage.writeCount == 0)
    }

    @Test
    func `one replay mode makes an unusable mixed baseline refuse every activation`() async throws {
        let recordProbe = StartupProbe()
        let replayProbe = StartupProbe()
        let recording = try recordProbe.system(key: "recording").withMode(.record)
        let replaying = try replayProbe.system(key: "replaying").withMode(.replay)

        let storage = StartupStorage(document: Data())
        let repository = try randomRepository(storage: storage)

        await #expect(throws: ScenarioRepositoryStartupFailure.self) {
            _ = try await Diorama(repository: repository,
                                  scenarioID: "repository-startup", mode: .passthrough,
                                  systems: recording, replaying).execute { _, _ in () }
        }
        #expect(recordProbe.preparationCount == 0)
        #expect(recordProbe.activationCount == 0)
        #expect(replayProbe.preparationCount == 0)
        #expect(replayProbe.activationCount == 0)
        #expect(storage.writeCount == 0)
    }
}

struct ScenarioRepositoryValidationTests {
    @Test
    func `persistence registration fails before storage and ignored system callbacks`() async throws {
        let probe = StartupProbe()
        let system = try probe.system(key: "ignored", allowsUnusedReplayRecords: true)

        let storage = try StartupStorage(document: persistedFixture("random-empty"))
        let repository = try JSONScenarioRepository(
            codec: JSONScenarioCodec(registry: PersistentSystemRegistry()),
            storage: storage)

        do {
            _ = try await Diorama(repository: repository,
                                  scenarioID: "registration", mode: .record,
                                  systems: system).execute { _ in () }
            Issue.record("Unregistered ignored setup started")
        } catch let error as ScenarioRepositoryStartupFailure {
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
    func `loaded values receive current preparation policy before any activation`() async throws {
        let probe = StartupProbe(failValidation: true)
        let system = try probe.system(key: "boundaries")
        let storage = try StartupStorage(document: persistedFixture("random-boundaries"))
        let repository = try randomRepository(storage: storage)

        do {
            _ = try await Diorama(repository: repository,
                                  scenarioID: "repository-startup", mode: .replay,
                                  systems: system).execute { _ in () }
            Issue.record("Current-policy validation failure returned an execution")
        } catch let error as ScenarioRepositoryStartupFailure {
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
        let result = try await Diorama(repository: repository,
                                       scenarioID: "repository-startup", mode: .replay,
                                       systems: system).execute { lease in try lease.claimNext().value }
        #expect(result.body == 1842)

        guard case let .loaded(baseline, _) = result.loadResult else {
            Issue.record("Expected the exact loaded baseline"); return
        }
        #expect(baseline.attachments.map(\.id.key.rawValue) == ["account-id", "retry-jitter"])
        #expect(result.finalization.usage.map(\.attachmentID.key.rawValue) == ["account-id"])
        #expect(result.finalization.report.diagnostics.map(\.diagnostic.issue) == [
            .baseline(.loadedAttachmentNotConfigured),
        ])
        #expect(result.finalization.report.diagnostics.map(\.diagnostic.context) == [
            .attachment(AttachmentID(
                systemTypeID: DioramaRandomSystem.systemTypeID,
                key: AttachmentKey(rawValue: "retry-jitter"))),
        ])
    }
}
