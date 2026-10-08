import Diorama
import DioramaCore
import DioramaDate
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DatePersistenceConformanceTests {
    @Test
    func `portable multiwall golden replays absolute dates and canonical offsets with a runtime clock`() async throws {
        let bytes = try DateConformanceSupport.fixture()
        let codec = try DateConformanceSupport.codec()
        let definition = try codec.decode(bytes)
        #expect(try codec.encode(definition) == bytes)
        let capture = try DateConformanceSupport.offline("capture")
        let replay = try DateConformanceSupport.offline("replay")
        let pass = try DateConformanceSupport.offline("pass")
        let empty = try DateConformanceSupport.offline("empty")
        let result = try await Diorama(definition: definition, scenarioID: "golden", mode: .replay,
                                       systems: capture, replay, pass, empty)
            .execute { context, capture, replay, pass, _ in
                let start = context.clock.now
                #expect((0..<3).map { _ in capture.now } == [
                    1_893_448_802.125, 1_893_448_807.125, 1_893_448_806.125,
                ].map { Date(timeIntervalSince1970: $0) })
                #expect((0..<3).map { _ in replay.now } == [0.001, 0.001, -1.499].map {
                    Date(timeIntervalSince1970: $0)
                })
                #expect((0..<2).map { _ in pass.now } == [1_751_353_200.0, 1_751_353_201].map {
                    Date(timeIntervalSince1970: $0)
                })
                try await context.clock.sleep(until: start.advanced(by: .milliseconds(2)))
                #expect(start.duration(to: context.clock.now) >= .milliseconds(2))
            }
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.finalization.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(result.finalization.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(try codec.encode(#require(result.definition)) == bytes)
    }

    @Test
    func `file rerecord preserves overrides and mixed walls while clock operations add no content`() async throws {
        let bytes = try DateConformanceSupport.fixture()
        let file = try DateConformanceSupport.file(bytes)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let source = DateConformanceSupport.Source([2000.00049, 2002.00049, 2009.00049])
        let passive = DateConformanceSupport.Source([100, -500])
        let capture = try DioramaDateSystem.instance(named: "capture") { source }
        let replay = try DateConformanceSupport.offline("replay").withMode(.replay)
        let pass = try DioramaDateSystem.instance(named: "pass") { passive }.withMode(.passthrough)
        let empty = try DateConformanceSupport.offline("empty").withMode(.replay)
        let recorded = try await Diorama(file: file, scenarioID: "mixed-file", mode: .record,
                                         systems: capture, replay, pass, empty)
            .execute { context, capture, replay, pass, _ in
                let before = context.clock.now
                let native = (0..<3).map { _ in capture.now }
                #expect(pass.now == Date(timeIntervalSince1970: 100))
                try await context.clock.sleep(for: .milliseconds(2))
                #expect(pass.now == Date(timeIntervalSince1970: -500))
                #expect(before < context.clock.now)
                _ = (0..<3).map { _ in replay.now }
                return native
            }
        #expect(recorded.body == [2000.00049, 2002.00049, 2009.00049].map { Date(timeIntervalSince1970: $0) })
        #expect(recorded.report.disposition == .published)
        #expect(recorded.report.diagnostics.isEmpty)
        let published = try Data(contentsOf: file)
        let expected = try #require(String(data: bytes, encoding: .utf8))
            .replacingOccurrences(of: "\"-1s\"", with: "\"7s\"")
        #expect(published == Data(expected.utf8))
        let offlineCapture = try DateConformanceSupport.offline("capture")
        let offlinePass = try DateConformanceSupport.offline("pass")
        let replayed = try await Diorama(file: file, scenarioID: "offline-file", mode: .replay,
                                         systems: offlineCapture, replay, offlinePass, empty)
            .execute { context, capture, replay, pass, _ in
                try await context.clock.sleep(for: .milliseconds(1))
                _ = (0..<3).map { _ in replay.now }
                _ = (0..<2).map { _ in pass.now }
                return (0..<3).map { _ in capture.now }
            }
        #expect(replayed.body == [1_893_448_802.125, 1_893_448_807.125, 1_893_448_814.125].map {
            Date(timeIntervalSince1970: $0)
        })
        #expect(replayed.finalization.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(replayed.finalization.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(replayed.report.diagnostics.isEmpty)
        #expect(replayed.report.disposition == .notRequested)
        #expect(try Data(contentsOf: file) == published)
        #expect(source.count == 3)
        #expect(passive.count == 2)
    }

    @Test
    func `file execution clock requires no wall system registration or payload`() async throws {
        let expected = """
        {
          "diorama" : {
            "schemaVersion" : 1
          },
          "systems" : [

          ]
        }

        """
        let bytes = Data(expected.utf8)
        let file = try DateConformanceSupport.file(bytes)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let recording = try await Diorama(file: file, scenarioID: "date-only-file", mode: .record)
            .execute { context in try await context.clock.sleep(for: .milliseconds(1)) }
        #expect(recording.finalization.usage.isEmpty)
        #expect(recording.definition?.attachments.isEmpty == true)
        #expect(recording.report.diagnostics.isEmpty)
        #expect(recording.report.disposition == .notRequested)
        let replay = try await Diorama(file: file, scenarioID: "date-only-file", mode: .replay)
            .execute { context in try await context.clock.sleep(for: .milliseconds(1)) }
        #expect(replay.finalization.usage.isEmpty)
        #expect(replay.report.diagnostics.isEmpty)
        #expect(replay.report.disposition == .notRequested)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test
    func `configured unused wall publishes an empty payload despite execution clock activity`() async throws {
        let file = try DateConformanceSupport.file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let source = DateConformanceSupport.Source([])
        let system = try DioramaDateSystem.instance(named: "clock") { source }
        let recorded = try await Diorama(file: file, scenarioID: "empty-wall", mode: .record, systems: system)
            .execute { context, _ in try await context.clock.sleep(for: .milliseconds(1)) }
        let bytes = try Data(contentsOf: file)
        #expect(try bytes == (DateConformanceSupport.fixture("date-empty")))
        #expect(recorded.report.disposition == .published)
        #expect(recorded.report.diagnostics.isEmpty)
        let replayed = try await Diorama(file: file, scenarioID: "empty-wall", mode: .replay, systems: system)
            .execute { context, _ in try await context.clock.sleep(for: .milliseconds(1)) }
        #expect(replayed.report.diagnostics.isEmpty)
        #expect(replayed.finalization.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(replayed.finalization.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(source.count == 0)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test
    func `concurrent callers consume one serialized wall sequence without assigning task order`() async throws {
        let native = (0..<32).map { Double($0) / 4 }
        let source = DateConformanceSupport.Source(native)
        let system = try DioramaDateSystem.instance(named: "concurrent") { source }
        let recorded = try await Diorama(scenarioID: "concurrent", mode: .record, systems: system)
            .execute { context, wall in try await concurrentReads(wall, clock: context.clock) }
        #expect(recorded.body == native.map { Date(timeIntervalSince1970: $0) })
        #expect(recorded.report.diagnostics.isEmpty)
        let definition = try #require(recorded.definition)
        let replay = try await Diorama(definition: definition, scenarioID: "concurrent", mode: .replay, systems: system)
            .execute { context, wall in try await concurrentReads(wall, clock: context.clock) }
        #expect(replay.body == recorded.body)
        #expect(replay.finalization.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(replay.finalization.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(replay.report.diagnostics.isEmpty)
        #expect(source.count == native.count)
    }

    private func concurrentReads(_ wall: any DioramaDateSource, clock: ScenarioClock) async throws -> [Date] {
        try await withThrowingTaskGroup(of: Date.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try await clock.sleep(for: .zero)
                    return wall.now
                }
            }
            var dates: [Date] = []
            for try await date in group {
                dates.append(date)
            }
            return dates.sorted()
        }
    }
}
