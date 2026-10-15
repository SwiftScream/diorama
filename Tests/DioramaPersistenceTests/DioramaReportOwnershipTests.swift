import Diorama
import DioramaCore
import DioramaPersistence
import DioramaRandom
import Foundation
import Synchronization
import Testing

struct DioramaReportOwnershipTests {
    @Test
    func `retained report releases decoded baseline payloads but returned load outcome preserves them`() async throws {
        let releases = Mutex(0)
        let layout = try DioramaRandomSystem.instance(named: "fixture").attachment
        let registration = PersistentSystemRegistration(
            currentSchemaVersion: 1, payloadType: PublicationFixtures.Payload.self,
            encode: { _ in throw PublicationFixtures.Failure.encoding },
            decode: { _, key in
                let id = AttachmentID(systemTypeID: layout.id.systemTypeID, key: key)
                let payload = LifetimePayload(onRelease: { releases.withLock { $0 += 1 } })
                return try ScenarioAttachment(id: id).adding(SequentialTrack(
                    id: TrackID(attachmentID: id, key: layout.trackIDs[0].key),
                    values: PersistentSystemRegistryTests.prepared([payload])))
            })
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([
            ScenarioSystemType(id: layout.id.systemTypeID, persistence: registration),
        ]))
        let storage = try PublicationStorage(document: persistedFixture("random-boundaries"))
        let setup = try Diorama(repository: JSONScenarioRepository(codec: codec, storage: storage),
                                scenarioID: "baseline-lifetime", mode: .record)
        let saved: DioramaReport
        do {
            let result = try await setup.execute { _ in 42 }
            saved = result.report
            guard case let .loaded(definition, _) = result.loadResult else {
                Issue.record("Expected a decoded baseline"); return
            }
            #expect(definition.attachments.count == 1)
            #expect(result.definition?.attachments.isEmpty == true)
            #expect(releases.withLock { $0 } == 0)
            withExtendedLifetime(result) {}
        }
        #expect(releases.withLock { $0 } == 1)
        #expect(saved == setup.report)
        #expect(saved.publication.priorDocument == .present)
        #expect(saved.evaluated(.healthyRecording).isSatisfied)
        #expect(saved.finalization.usage.isEmpty)
        withExtendedLifetime(setup) {}
    }

    @Test(arguments: [false, true], [false, true])
    func `safe reports release publication errors after either body outcome`(throwBody: Bool, cleanup: Bool)
        async throws
    {
        let releases = Mutex(0)
        let descriptions = Mutex(0)
        let storage = ErrorStorage(cleanup: cleanup,
                                   onRelease: { releases.withLock { $0 += 1 } },
                                   onDescription: { descriptions.withLock { $0 += 1 } })
        let setup = try Diorama(
            repository: JSONScenarioRepository(codec: PublicationFixtures.codec(), storage: storage),
            scenarioID: "error-lifetime", mode: .record, systems: StartupProbe().system(key: "record"))
        do {
            let result = try await setup.execute { _, lease in
                try lease.record(capturing: { 42 }, preparation: ValuePreparation<UInt64>())
                if throwBody {
                    throw PublicationFixtures.Failure.body
                }
                return 7
            }
            #expect(!throwBody)
            #expect(result.body == 7)
            #expect(try PublicationFixtures.values("record", in: #require(result.definition)) == [42])
            switch result.publication {
            case let .failed(.storage(error)):
                #expect(!cleanup)
                #expect(error is RetainedError)
            case let .published(receipt):
                #expect(cleanup)
                #expect(receipt.cleanupFailure is RetainedError)
            default: Issue.record("Expected detailed publication failure evidence")
            }
            #expect(releases.withLock { $0 } == 0)
            #expect(result.report == setup.report)
            withExtendedLifetime(result) {}
        } catch {
            #expect(throwBody)
            #expect(error as? PublicationFixtures.Failure == .body)
        }
        let report = try #require(setup.report)
        #expect(releases.withLock { $0 } == 1)
        #expect(report.publication.disposition == (cleanup ? .published : .failed))
        #expect(report.publication.issues.map(\.stage) == [cleanup ? .cleanup : .storage(nil)])
        #expect(report.publication.issues.map(\.cause) == [.unspecified])
        #expect(report.evaluated(.noDiagnostics).isSatisfied)
        #expect(report.evaluated(.successfulCleanup).isSatisfied)
        #expect(!report.rendered().contains("SECRET-PUBLICATION-ERROR"))
        #expect(descriptions.withLock { $0 } == 0)
        withExtendedLifetime(setup) {}
    }
}

private final class LifetimePayload: Sendable {
    let onRelease: @Sendable () -> Void
    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

private struct RetainedError: Error, CustomStringConvertible {
    let payload: LifetimePayload
    let onDescription: @Sendable () -> Void
    var description: String {
        onDescription()
        return "SECRET-PUBLICATION-ERROR"
    }
}

private struct ErrorStorage: ScenarioDocumentStorage {
    let cleanup: Bool
    let onRelease: @Sendable () -> Void
    let onDescription: @Sendable () -> Void
    func load() -> Data? {
        nil
    }

    func publish(_: Data) throws -> DocumentPublication {
        let error = RetainedError(payload: LifetimePayload(onRelease: onRelease), onDescription: onDescription)
        if cleanup {
            return DocumentPublication(cleanupFailure: error)
        }
        throw error
    }
}
