import Diorama
import DioramaCore
import DioramaDate
import Foundation
import Testing

struct PurePassthroughDateTests {
    @Test
    func `passthrough bypasses runtime date content policies and preserves the baseline`() async throws {
        let source = DateConformanceSupport.Source([100_000_000_000_000])
        let system = try DioramaDateSystem.instance(named: "live") { source }
        let id = try #require(system.attachment.trackIDs.first)
        let header = try ValuePreparation<Int?>().admitPrepared(2000)
        let value = try ValuePreparation<OverridableValue<Date>>().admitPrepared(
            .observed(Date(timeIntervalSince1970: .infinity)))
        let baseline = try ScenarioAttachment(id: system.attachment.id).adding(
            SequentialTrack(id: id, header: header, values: [value]))
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [baseline]),
            scenarioID: ScenarioID(rawValue: "native-content"), defaultMode: .passthrough,
            systems: [AnyScenarioSystem(system)])
        let wall = try execution.dependency(system)
        let result = await execution.finish()
        #expect(wall.now == Date(timeIntervalSince1970: 100_000_000_000_000))
        let attachment = try #require(result.definition?.attachments.first)
        let track = try #require(try attachment.track(id, as: OverridableValue<Date>.self, header: Int?.self))
        #expect(track.header == 2000)
        #expect(track.records.first?.value.value.timeIntervalSince1970.isInfinite == true)
        #expect(result.usage[0].tracks[0].activity == .passthrough)
        #expect(result.report.diagnostics.isEmpty)
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
    }

    @Test
    func `passthrough retains strict decoding and its existing unusable baseline policy`() async throws {
        let bytes = Data("""
        {"diorama":{"schemaVersion":1},"systems":[{"attachmentKey":"live",\
        "type":"diorama.date","schemaVersion":1,\
        "payload":{"origin":"not-a-date","observations":["0ms"]}}]}
        """.utf8)
        let file = try DateConformanceSupport.file(bytes)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(throws: (any Error).self) { _ = try DateConformanceSupport.codec().decode(bytes) }
        let source = DateConformanceSupport.Source([42])
        let system = try DioramaDateSystem.instance(named: "live") { source }
        let setup = try Diorama(file: file, scenarioID: "native-decoding", mode: .passthrough, systems: system)
        let result = try await setup.execute { _, wall in wall.now }
        #expect(result.body == Date(timeIntervalSince1970: 42))
        guard case .invalidDocument = result.loadResult else {
            Issue.record("Passthrough must retain the decoder's failure")
            return
        }
        #expect(result.report.disposition == .notRequested)
        #expect(try Data(contentsOf: file) == bytes)
    }
}
