import Diorama
import DioramaCore
import DioramaPersistence
@testable import DioramaRandom
import Foundation
import Testing

struct DioramaRepositoryTests {
    @Test
    func `custom repository construction is lazy and each start loads exactly once`() async throws {
        let storage = try StartupStorage(document: persistedFixture("random-boundaries"))
        let repository = try randomRepository(storage: storage)
        let probe = StartupProbe()
        let system = try probe.system(key: "boundaries")
        let setup = try Diorama(repository: repository, scenarioID: "repository-setup",
                                mode: .replay, systems: system)
        #expect(storage.readCount == 0)
        #expect(probe.preparationCount == 0)
        for expectedReads in 1...2 {
            let result = try await setup.execute { lease in try lease.claimNext().value }
            #expect(result.body == 0)
            guard case let .loaded(baseline, _) = result.loadResult else {
                Issue.record("Exact loaded baseline was not retained"); return
            }
            let track = try baseline.attachments[0].track(DioramaRandomSystem.trackID(
                for: AttachmentKey(rawValue: "boundaries")), as: UInt64.self)
            #expect(track?.records.map(\.value) == [0, UInt64.max])
            #expect(storage.readCount == expectedReads)
        }
        #expect(probe.activationCount == 2)
        #expect(storage.writeCount == 0)
    }

    @Test(arguments: ["missing", "unreadable", "invalid", "envelope", "system"])
    func `reusable repository startup preserves exact failure evidence`(kind: String) async throws {
        let storage = try failureStorage(kind)
        let repository = try randomRepository(storage: storage)
        let probe = StartupProbe()
        let system = try probe.system(key: "boundaries")
        let setup = try Diorama(repository: repository, scenarioID: "repository-setup",
                                mode: .replay, systems: system)
        do {
            _ = try await setup.execute { _ in Issue.record("Unusable replay invoked body") }
            Issue.record("Unusable replay started")
        } catch let error as ScenarioRepositoryStartupFailure {
            guard case let .load(result) = error.evidence else {
                Issue.record("Missing load failure evidence"); return
            }
            #expect(loadProblem(result) == loadProblem(repository.load()))
            #expect(try error.startupFailure.report.diagnostics.map(\.diagnostic.issue) == [
                .baseline(.requiredBaselineUnavailable(#require(loadProblem(result)))),
            ])
        }
        #expect(probe.preparationCount == 0)
        #expect(probe.activationCount == 0)
        #expect(storage.writeCount == 0)
    }

    @Test
    func `missing and invalid record baselines retain exact evidence without writes`() async throws {
        for storage in [StartupStorage(), StartupStorage(document: Data())] {
            let system = try StartupProbe().system(key: "record")
            let setup = try Diorama(
                repository: randomRepository(storage: storage), scenarioID: "repository-setup",
                mode: .record, systems: system)
            let result = try await setup.execute { lease in
                try lease.append(capturing: { 42 }, preparation: ValuePreparation<UInt64>())
            }
            let baselineProblem = try loadProblem(#require(result.loadResult))
            #expect(baselineProblem == .missing || baselineProblem == .invalidDocument)
            #expect(result.finalization.usage[0].tracks[0].activity == .record(recordedCount: 1, incompleteCount: 0))
            #expect(storage.readCount == 1)
            #expect(storage.writeCount == 0)
        }
    }

    @Test
    func `nonpersistable repository setup fails before reading or preparing`() async throws {
        let storage = StartupStorage()
        let repository = try JSONScenarioRepository(codec: JSONScenarioCodec(registry: PersistentSystemRegistry()),
                                                    storage: storage)
        let probe = StartupProbe()
        let system = try probe.system(key: "unregistered")
        let setup = try Diorama(repository: repository, scenarioID: "repository-setup",
                                mode: .passthrough, systems: system)
        do {
            _ = try await setup.execute { _ in () }
            Issue.record("Unregistered active system started")
        } catch let error as ScenarioRepositoryStartupFailure {
            guard case let .persistenceConfiguration(problem) = error.evidence else {
                Issue.record("Missing registration evidence"); return
            }
            #expect(problem == .unknownSystemType(DioramaRandomSystem.type.id))
        }
        #expect(storage.readCount == 0)
        #expect(probe.preparationCount == 0)
    }

    @Test
    func `repeated scoped repository runs produce identical finalization`() async throws {
        let storage = try StartupStorage(document: persistedFixture("random-boundaries"))
        let repository = try randomRepository(storage: storage)
        let system = try StartupProbe().system(key: "boundaries")
        let scenarioID = "repository-setup"
        let setup = try Diorama(repository: repository, scenarioID: scenarioID, mode: .replay, systems: system)
        let high = try await setup.execute { lease in try lease.claimNext().value }
        let second = try await setup.execute { lease in try lease.claimNext().value }
        #expect(second.body == high.body)
        #expect(second.finalization == high.finalization)
        #expect(storage.readCount == 2)
        #expect(storage.writeCount == 0)
    }
}
