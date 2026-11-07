import Diorama
import DioramaCore
import DioramaPersistence
import Foundation
import Testing

struct DioramaPassthroughPublicationTests {
    @Test(arguments: ["memory", "fixed", "missing", "invalid", "partial"], [false, true])
    func `unrecorded passthrough stays live but is absent from semantic and persisted output`(
        source: String, defaultPassthrough: Bool) async throws
    {
        let probe = StartupProbe()
        let record = try probe.system(key: "record").withMode(.record)
        let live = try probe.system(key: "live").withMode(defaultPassthrough ? nil : .passthrough)
        let mode: ScenarioMode = defaultPassthrough ? .passthrough : .record
        let codec = try PublicationFixtures.codec()
        let baseline = try PublicationFixtures.definition([("record", [1])])
        let storage = try PublicationStorage(document: source == "partial" ? codec.encode(baseline)
            : source == "invalid" ? Data() : nil)
        let setup: Diorama<StartupDependency, StartupDependency> = switch source {
        case "memory": try Diorama(scenarioID: "mixed", mode: mode, systems: live, record)
        case "fixed":
            try Diorama(definition: baseline, scenarioID: "mixed", mode: mode, systems: live, record)
        default:
            try Diorama(repository: randomRepository(storage: storage),
                        scenarioID: "mixed", mode: mode, systems: live, record)
        }
        let result = try await setup.execute { _, live, record in
            guard case .passthrough = live else { Issue.record("Expected a live dependency"); return }
            try record.record(capturing: { 42 }, preparation: ValuePreparation())
        }
        let definition = try #require(result.definition)
        #expect(definition.attachments.map(\.id) == [record.attachment.id])
        #expect(try PublicationFixtures.values("record", in: definition) == [42])
        #expect(probe.activationCount == 2)
        #expect(result.report.finalization.cleanup.map(\.attachmentID) == [live.attachment.id, record.attachment.id])
        #expect(result.report.finalization.usage.map(\.attachmentID) == [live.attachment.id, record.attachment.id])
        #expect(result.report.finalization.usage[0].tracks[0].activity == .passthrough)
        #expect(result.report.publication.candidate.attachmentCount == 1)
        #expect(result.report.publication.candidate.trackCount == 1)
        #expect(result.report.publication.candidate.recordedCount == 1)
        if source == "memory" || source == "fixed" {
            #expect(result.report.publication.disposition == .notRequested)
        } else {
            #expect(result.report.publication.disposition == .published)
            #expect(storage.writeCount == 1)
            let decoded = try codec.decode(#require(storage.document))
            #expect(decoded.attachments.map(\.id) == [record.attachment.id])
            #expect(try codec.encode(decoded) == codec.encode(definition))
        }
        let replay = try Diorama(definition: definition, scenarioID: "replay", mode: .replay,
                                 systems: record.withMode(.replay), live.withMode(.replay))
        await #expect(throws: ScenarioStartupFailure.self) {
            try await replay.execute { _, _, _ in Issue.record("Absent recording must not replay") }
        }
        #expect(probe.activationCount == 2)
    }

    @Test
    func `empty baseline passthrough survives alongside a newly omitted keyed instance`() async throws {
        let codec = try PublicationFixtures.codec()
        let baseline = try PublicationFixtures.definition([("kept", []), ("record", [1])])
        let bytes = try codec.encode(baseline)
        let storage = PublicationStorage(document: bytes)
        let probe = StartupProbe()
        let kept = try probe.system(key: "kept").withMode(.passthrough)
        let absent = try probe.system(key: "absent").withMode(.passthrough)
        let record = try probe.system(key: "record")
        let result = try await Diorama(repository: randomRepository(storage: storage),
                                       scenarioID: "preserve", mode: .record, systems: kept, absent, record)
            .execute { _, _, _, record in
                try record.record(capturing: { 42 }, preparation: ValuePreparation())
            }
        let definition = try #require(result.definition)
        #expect(definition.attachments.map(\.id) == [kept.attachment.id, record.attachment.id])
        #expect(try PublicationFixtures.values("kept", in: definition).isEmpty)
        #expect(try PublicationFixtures.values("record", in: definition) == [42])
        #expect(try codec.encode(baseline) == bytes)
        #expect(try codec.encode(definition) == storage.document)
        #expect(result.report.publication.disposition == .published)
        #expect(result.report.publication.candidate.attachmentCount == 2)
        #expect(result.report.finalization.usage.count == 3)
    }

    @Test
    func `fresh all passthrough returns an empty definition without writing`() async throws {
        let storage = PublicationStorage()
        let live = try StartupProbe().system(key: "live")
        let result = try await Diorama(repository: randomRepository(storage: storage),
                                       scenarioID: "live", mode: .passthrough, systems: live)
            .execute { _, live in
                guard case .passthrough = live else { Issue.record("Expected live passthrough"); return }
            }
        #expect(try #require(result.definition).attachments.isEmpty)
        #expect(result.report.publication.disposition == .notRequested)
        #expect(result.report.publication.candidate.attachmentCount == 0)
        #expect(result.report.publication.candidate.trackCount == 0)
        #expect(result.report.finalization.usage.count == 1)
        #expect(result.report.finalization.cleanup.count == 1)
        #expect(storage.writeCount == 0)
    }
}
