import Diorama
import DioramaCore
import DioramaPersistence
import DioramaRandom
import Foundation
import Testing

struct DioramaPublicationTests {
    @Test
    func `mixed modes publish one complete replacement and omit unconfigured attachments`() async throws {
        let baseline = try PublicationFixtures.definition([
            ("record", [1, 2]), ("replay", [3, 4]), ("passthrough", [5, 6]),
            ("ignored", [7, 8]), ("omitted", [9]),
        ])
        let codec = try PublicationFixtures.codec()
        let bytes = try codec.encode(baseline)
        let storage = PublicationStorage(document: bytes)
        let probe = StartupProbe()
        let record = try probe.system(key: "record")
        let replay = try probe.system(key: "replay").withMode(.replay)
        let passthrough = try probe.system(key: "passthrough").withMode(.passthrough)
        let ignored = try probe.system(key: "ignored", allowsUnusedReplayRecords: true).withMode(.replay)
        let result = try await Diorama(repository: randomRepository(storage: storage),
                                       scenarioID: "mixed", mode: .record,
                                       systems: record, replay, passthrough, ignored)
            .execute { record, replay, _, _ in
                try record.append(capturing: { 42 }, preparation: ValuePreparation<UInt64>())
                #expect(try replay.claimNext().value == 3)
                #expect(storage.writeCount == 0)
                #expect(storage.document == bytes)
            }
        let definition = try #require(result.definition)
        #expect(definition.attachments.map(\.id.key.rawValue) == ["record", "replay", "passthrough", "ignored"])
        let expectations: [(String, [UInt64])] = [
            ("record", [42]), ("replay", [3, 4]), ("passthrough", [5, 6]), ("ignored", [7, 8]),
        ]
        for (key, expected) in expectations {
            #expect(try PublicationFixtures.values(key, in: definition) == expected)
        }
        #expect(result.finalization.report.diagnostics.map(\.diagnostic.issue) == [
            .baseline(.loadedAttachmentNotConfigured),
        ])
        #expect(result.finalization.usage.last?.allowsUnusedReplayRecords == true)
        #expect(try codec.encode(baseline) == bytes)
        #expect(storage.readCount == 1)
        #expect(storage.writeCount == 1)
        #expect(try codec.encode(definition) == storage.document)
        guard case .published = result.publication else { Issue.record("Expected a committed candidate"); return }
    }

    @Test(arguments: [ScenarioMode.replay, .passthrough])
    func `runs without recording return preserved definitions without writes`(mode: ScenarioMode) async throws {
        let bytes = try persistedFixture("random-boundaries")
        let storage = PublicationStorage(document: bytes)
        let system = try StartupProbe().system(key: "boundaries")
        let result = try await Diorama(repository: randomRepository(storage: storage),
                                       scenarioID: "preserve", mode: mode, systems: system)
            .execute { lease in
                if mode == .replay {
                    _ = try lease.claimNext()
                }
            }
        let definition = try #require(result.definition)
        #expect(try PublicationFixtures.codec().encode(definition) == bytes)
        #expect(storage.document == bytes)
        #expect(storage.writeCount == 0)
        guard case .notRequested = result.publication else { Issue.record("Unexpected write request"); return }
    }

    @Test(arguments: [false, true])
    func `encoding and storage failure retain valid output for direct replay`(failEncoding: Bool) async throws {
        let bytes = try persistedFixture("random-boundaries")
        let storage = PublicationStorage(document: bytes, beforeCommit: { throw PublicationFixtures.Failure.storage })
        let codec: JSONScenarioCodec
        if failEncoding {
            let registration = PersistentSystemRegistration(
                currentSchemaVersion: 1, payloadType: PublicationFixtures.Payload.self,
                encode: { _ in throw PublicationFixtures.Failure.encoding },
                decode: { payload, key in
                    try PublicationFixtures.definition([(key.rawValue, payload.values)]).attachments[0]
                })
            let random = try DioramaRandomSystem.instance(named: "fixture")
            codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([
                ScenarioSystemType(id: random.type.id, persistence: registration),
            ]))
        } else {
            codec = try PublicationFixtures.codec()
        }
        let system = try StartupProbe().system(key: "boundaries")
        let result = try await Diorama(repository: JSONScenarioRepository(codec: codec, storage: storage),
                                       scenarioID: "failure", mode: .record, systems: system)
            .execute { lease in
                try lease.append(capturing: { 42 }, preparation: ValuePreparation<UInt64>())
                return "body value"
            }
        #expect(result.body == "body value")
        let definition = try #require(result.definition)
        #expect(result.finalization.report.recordingHealth.isHealthy)
        guard case let .failed(error) = result.publication else { Issue.record("Expected publication failure"); return }
        switch error {
        case let .encoding(cause):
            #expect(failEncoding)
            #expect(cause as? PublicationFixtures.Failure == .encoding)
        case let .storage(cause):
            #expect(!failEncoding)
            #expect(cause as? PublicationFixtures.Failure == .storage)
        }
        #expect(storage.document == bytes)
        #expect(storage.writeCount == (failEncoding ? 0 : 1))
        let replay = try await Diorama(definition: definition, scenarioID: "retained", mode: .replay, systems: system)
            .execute { lease in try lease.claimNext().value }
        #expect(replay.body == 42)
    }

    @Test(arguments: ["success", "throw", "cancel", "cancel-return"], [false, true])
    func `body outcome does not control publication health`(outcome: String, unhealthy: Bool) async throws {
        let bytes = try persistedFixture("random-boundaries")
        let storage = PublicationStorage(document: bytes)
        let system = try StartupProbe().system(key: "boundaries")
        let setup = try Diorama(repository: randomRepository(storage: storage),
                                scenarioID: "body-outcome", mode: .record, systems: system)
        let task = Task {
            try await setup.execute { lease in
                try lease.append(capturing: { 42 }, preparation: ValuePreparation<UInt64>())
                if unhealthy {
                    _ = lease.report(.system(DiagnosticLabel("invalid-recording")),
                                     recordingImpact: .invalidatesCandidate)
                }
                try applyBodyOutcome(outcome)
                return 123
            }
        }
        do {
            let result = try await task.value
            #expect(outcome == "success" || outcome == "cancel-return")
            #expect(result.body == 123)
            #expect((result.definition == nil) == unhealthy)
            if unhealthy {
                guard case .refusedUnhealthy = result.publication else {
                    Issue.record("Unhealthy candidate published"); return
                }
            } else {
                guard case .published = result.publication else {
                    Issue.record("Healthy candidate was not published"); return
                }
            }
        } catch {
            if outcome == "cancel" {
                #expect(error is CancellationError)
            } else {
                #expect(outcome == "throw")
                #expect(error as? PublicationFixtures.Failure == .body)
            }
        }
        #expect(storage.writeCount == (unhealthy ? 0 : 1))
        if unhealthy {
            #expect(storage.document == bytes)
        } else {
            let definition = try PublicationFixtures.codec().decode(#require(storage.document))
            #expect(try PublicationFixtures.values("boundaries", in: definition) == [42])
        }
    }

    private func applyBodyOutcome(_ outcome: String) throws {
        switch outcome {
        case "throw": throw PublicationFixtures.Failure.body
        case "cancel":
            withUnsafeCurrentTask { $0?.cancel() }
            try Task.checkCancellation()
        case "cancel-return": withUnsafeCurrentTask { $0?.cancel() }
        default: break
        }
    }
}
