import Diorama
import DioramaCore
@testable import DioramaDate
import Foundation
import Testing

struct WallRangePersistenceTests {
    @Test(arguments: [ScenarioMode.record, .replay])
    func `out of range prepared baselines fail before source activation`(mode: ScenarioMode) throws {
        let system = try DioramaDateSystem.instance(named: "clock") {
            Issue.record("Invalid baseline must fail before activation")
            return DateConformanceSupport.Source([])
        }
        let trackID = try #require(system.attachment.trackIDs.first)
        let value = try ValuePreparation<OverridableValue<Date>>().admitPrepared(
            .override(Date(timeIntervalSince1970: 100_000_000_000_000)))
        let header = try ValuePreparation<Int?>().admitPrepared(0)
        let attachment = try ScenarioAttachment(id: system.attachment.id).adding(
            SequentialTrack(id: trackID, header: header, values: [value]))
        #expect(throws: ScenarioStartupFailure.self) {
            _ = try ScenarioExecution.start(
                definition: ScenarioDefinition(attachments: [attachment]),
                scenarioID: ScenarioID(rawValue: "range"), defaultMode: mode,
                systems: [AnyScenarioSystem(system)])
        }
    }

    @Test(arguments: [100_000_000_000_000.0, -62_135_500_000.001, 253_402_250_000.001])
    func `unsupported native dates cannot replace a valid file`(seconds: Double) async throws {
        let bytes = try DateConformanceSupport.fixture("date-empty")
        let file = try DateConformanceSupport.file(bytes)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let source = DateConformanceSupport.Source([seconds])
        let system = try DioramaDateSystem.instance(named: "clock") { source }
        let result = try await Diorama(file: file, scenarioID: "range", mode: .record, systems: system)
            .execute { _, wall in wall.now }
        #expect(result.body == Date(timeIntervalSince1970: seconds))
        #expect(result.definition == nil)
        #expect(result.finalization.report.diagnostics.map(\.diagnostic.issue) == [.conversionFailed])
        #expect(result.report.disposition == .refusedUnhealthy)
        #expect(result.report.preservation == .unchangedByThisRun)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(source.count == 1)
    }

    @Test
    func `supported native observations retain milliseconds through file replay`() async throws {
        let file = try DateConformanceSupport.file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let seconds = [-1.001, 0, 1.001, 1.001, -2.125]
        let source = DateConformanceSupport.Source(seconds)
        let system = try DioramaDateSystem.instance(named: "clock") { source }
        let recorded = try await Diorama(file: file, scenarioID: "range", mode: .record, systems: system)
            .execute { _, wall in seconds.map { _ in wall.now } }
        #expect(recorded.report.disposition == .published)
        let replay = try await Diorama(file: file, scenarioID: "range", mode: .replay,
                                       systems: DateConformanceSupport.offline("clock"))
            .execute { _, wall in seconds.map { _ in wall.now } }
        #expect(replay.body == recorded.body)
        #expect(replay.report.diagnostics.isEmpty)
        #expect(source.count == seconds.count)
    }

    @Test
    func `strict model rejects out of range origins observations and overrides`() throws {
        #expect(WallOrigin(date: Date(timeIntervalSince1970: 100_000_000_000_000), offsetMinutes: 0) == nil)
        for bound in [-62_135_500_000.0, 253_402_250_000.0] {
            let origin = try #require(WallOrigin(date: Date(timeIntervalSince1970: bound), offsetMinutes: 0))
            let delta: Int64 = bound < 0 ? -1 : 1
            #expect(throws: WallRecordingError.unrepresentableWallValue(position: 1)) {
                _ = try WallRecording(origin: .observed(origin), observations: [.observed(0), .observed(delta)])
            }
            #expect(throws: WallRecordingError.unrepresentableWallValue(position: 0)) {
                _ = try WallRecording(origin: .observed(origin), observations: [.override(delta)])
            }
        }
        let codec = try DateConformanceSupport.codec()
        let text = try #require(String(data: DateConformanceSupport.fixture("date-nonempty"), encoding: .utf8))
        let invalid = text.replacingOccurrences(of: "2030-01-01T09:00:00.000+11:00",
                                                with: "9999-12-31T23:59:59.999Z")
        #expect(throws: (any Error).self) { _ = try codec.decode(Data(invalid.utf8)) }
    }
}
