import Diorama
@testable import DioramaClock
import DioramaCore
import DioramaPersistence
import Foundation
import Synchronization
import Testing

enum WallMergeFixtures {
    static func codec() throws -> JSONScenarioCodec {
        try JSONScenarioCodec(registry: PersistentSystemRegistry([DioramaClockSystem.type]))
    }

    static func recording(
        origin: OverridableValue<Date>, deltas: [OverridableValue<Int64>],
        offset: Int = 660) throws -> WallRecording
    {
        let wallOrigin = try #require(WallOrigin(date: origin.value, offsetMinutes: offset))
        return try WallRecording(origin: origin.map { _ in wallOrigin }, observations: deltas)
    }

    static func content(_ definition: ScenarioDefinition, named name: String = "clock") throws -> WallRecording {
        let attachment = try #require(definition.attachment(for: AttachmentKey(rawValue: name)))
        return try DioramaClockSystem.recording(in: attachment)
    }

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func file(containing bytes: Data) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diorama-f05-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("scenario.json")
        try bytes.write(to: file)
        return file
    }

    final class Source: DioramaWallClock {
        private let values: [Date]
        private let reads = Mutex(0)

        init(_ values: [Date]) {
            self.values = values
        }

        var count: Int {
            reads.withLock { $0 }
        }

        var now: Date {
            reads.withLock { position in
                defer { position += 1 }
                guard position < values.count else {
                    Issue.record("Unexpected live wall read")
                    return Date(timeIntervalSince1970: 0)
                }
                return values[position]
            }
        }
    }
}

struct WallOverrideMergeTests {
    @Test
    func `keyed record replay and passthrough clocks keep independent override and source behavior`() async throws {
        let original = try WallMergeFixtures.recording(
            origin: .override(Date(timeIntervalSince1970: 1000)), deltas: [.observed(0), .override(5000)])
        let baseline = try ScenarioDefinition(attachments: [
            DioramaClockSystem.attachment(named: "record", recording: original),
            DioramaClockSystem.attachment(named: "replay", recording: original),
            DioramaClockSystem.attachment(named: "pass", recording: original),
        ])
        let source = WallMergeFixtures.Source([Date(timeIntervalSince1970: 2000), Date(timeIntervalSince1970: 2001)])
        let passthroughSource = WallMergeFixtures.Source([Date(timeIntervalSince1970: 3000)])
        let record = try DioramaClockSystem.instance(named: "record") { source }
        let replay = try DioramaClockSystem.instance(named: "replay") { () -> WallMergeFixtures.Source in
            Issue.record("Replay initialized a source")
            return WallMergeFixtures.Source([])
        }.withMode(.replay)
        let pass = try DioramaClockSystem.instance(named: "pass") { passthroughSource }.withMode(.passthrough)
        let result = try await Diorama(definition: baseline, scenarioID: "mixed", mode: .record,
                                       systems: record, replay, pass)
            .execute { record, replay, pass in
                #expect(record.now == Date(timeIntervalSince1970: 2000))
                #expect(record.now == Date(timeIntervalSince1970: 2001))
                #expect(replay.now == original.effectiveDates[0])
                #expect(replay.now == original.effectiveDates[1])
                #expect(pass.now == Date(timeIntervalSince1970: 3000))
            }
        let candidate = try #require(result.definition)
        for name in ["record", "replay", "pass"] {
            #expect(try WallMergeFixtures.content(candidate, named: name) == original)
            #expect(try WallMergeFixtures.content(baseline, named: name) == original)
        }
        #expect(result.finalization.report.diagnostics.isEmpty)
        #expect(source.count == 2)
        #expect(passthroughSource.count == 1)
    }

    @Test
    func `edited baseline rerecords to canonical overrides while live values remain native`() async throws {
        let codec = try WallMergeFixtures.codec()
        let baseline = try codec.decode(WallMergeFixtures.fixture("clock-edited"))
        let baselineBytes = try codec.encode(baseline)
        let native = [0.00049, 0.00098, 0.0004].map { Date(timeIntervalSince1970: 2_000_000_000 + $0) }
        let source = WallMergeFixtures.Source(native)
        let system = try DioramaClockSystem.instance(named: "clock") { source }
        let result = try await Diorama(definition: baseline, scenarioID: "rerecord", mode: .record, systems: system)
            .execute { wall in native.map { _ in wall.now } }
        #expect(result.body == native)
        #expect(source.count == native.count)
        let candidate = try #require(result.definition)
        let recording = try WallMergeFixtures.content(candidate)
        let old = try WallMergeFixtures.content(baseline)
        #expect(recording.origin == old.origin)
        #expect(recording.observations == [.observed(0), .override(5000), .observed(-1)])
        let expected = try WallMergeFixtures.fixture("clock-rerecorded-overrides")
        #expect(try codec.encode(candidate) == expected)
        #expect(try codec.encode(codec.decode(expected)) == expected)
        #expect(try codec.encode(baseline) == baselineBytes)
        #expect(result.finalization.report.diagnostics.isEmpty)
        #expect(!result.report.rendered().contains("2033-"))
        let replay = try await Diorama(definition: candidate, scenarioID: "replay", mode: .replay, systems: system)
            .execute { wall in native.map { _ in wall.now } }
        #expect(replay.body == recording.effectiveDates)
        #expect(source.count == native.count)
        #expect(replay.finalization.report.diagnostics.isEmpty)
    }

    @Test
    func `ordinary origin uses the fresh offset and later fresh deltas ignore earlier overrides`() async throws {
        let original = try WallMergeFixtures.recording(
            origin: .observed(Date(timeIntervalSince1970: 100)),
            deltas: [.observed(0), .override(5000), .observed(7000)], offset: -300)
        let attachment = try DioramaClockSystem.attachment(named: "clock", recording: original)
        let baseline = try ScenarioDefinition(attachments: [attachment])
        let native = [0.0, 2, 9].map { Date(timeIntervalSince1970: 2_000_000_000 + $0) }
        let source = WallMergeFixtures.Source(native)
        let system = try DioramaClockSystem.instance(named: "clock") { source }
        let zone = TimeZone.current
        let result = try await Diorama(definition: baseline, scenarioID: "fresh", mode: .record, systems: system)
            .execute { wall in native.map { _ in wall.now } }
        let candidate = try #require(result.definition)
        let merged = try WallMergeFixtures.content(candidate)
        #expect(result.body == native)
        #expect(merged.origin?.value.date == native[0])
        #expect(merged.origin?.isOverride == false)
        #expect(merged.origin?.value.offsetMinutes == zone.secondsFromGMT(for: native[0]) / 60)
        #expect(merged.observations == [.observed(0), .override(5000), .observed(7000)])
        #expect(merged.effectiveDates == [native[0], native[0].addingTimeInterval(5), native[0].addingTimeInterval(12)])
        #expect(try WallMergeFixtures.content(baseline) == original)
    }

    @Test(arguments: [
        ([0.0, 0.5, 1, 2, 3], [Int64(0), 500, 7000, 1000, 1000]),
        ([0.0, 2, 3], [Int64(0), 2000, 7000]),
        ([0.0, 1], [Int64(0), 1000]),
        ([Double](), [Int64]()),
    ])
    func `inserted and removed reads retain only overrides at surviving numeric positions`(
        offsets: [Double], deltas: [Int64]) async throws
    {
        let original = try WallMergeFixtures.recording(
            origin: .override(Date(timeIntervalSince1970: 1000)),
            deltas: [.observed(0), .observed(1000), .override(7000), .observed(1000)])
        let attachment = try DioramaClockSystem.attachment(named: "clock", recording: original)
        let baseline = try ScenarioDefinition(attachments: [attachment])
        let native = offsets.map { Date(timeIntervalSince1970: 2_000_000_000 + $0) }
        let source = WallMergeFixtures.Source(native)
        let system = try DioramaClockSystem.instance(named: "clock") { source }
        let result = try await Diorama(definition: baseline, scenarioID: "positions", mode: .record, systems: system)
            .execute { wall in native.map { _ in wall.now } }
        let merged = try WallMergeFixtures.content(#require(result.definition))
        #expect(result.body == native)
        #expect(merged.observations.map(\.value) == deltas)
        #expect(merged.observations.enumerated().allSatisfy { position, value in value.isOverride == (position == 2) })
        #expect(merged.origin == (native.isEmpty ? nil : original.origin))
        #expect(result.finalization.report.recordingHealth.isHealthy)
        #expect(result.finalization.report.diagnostics.isEmpty)
        #expect(try WallMergeFixtures.content(baseline) == original)
    }

    @Test(arguments: [false, true])
    func `dropping obsolete positional overrides or an entire recording publishes a healthy replacement`(
        empty: Bool) async throws
    {
        let codec = try WallMergeFixtures.codec()
        let bytes = try WallMergeFixtures.fixture("clock-edited-canonical")
        let file = try WallMergeFixtures.file(containing: bytes)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let native = empty ? [] : [Date(timeIntervalSince1970: 2_000_000_000)]
        let source = WallMergeFixtures.Source(native)
        let system = try DioramaClockSystem.instance(named: "clock") { source }
        let result = try await Diorama(file: file, scenarioID: "publish", mode: .record, systems: system)
            .execute { wall in native.map { _ in wall.now } }
        let candidate = try #require(result.definition)
        let merged = try WallMergeFixtures.content(candidate)
        #expect(merged.observations == (empty ? [] : [.observed(0)]))
        #expect(merged.origin?.isOverride == (empty ? nil : true))
        #expect(merged.offsetMinutes == (empty ? nil : 660))
        #expect(result.report.disposition == .published)
        #expect(result.report.issues.isEmpty)
        #expect(result.finalization.report.diagnostics.isEmpty)
        #expect(try Data(contentsOf: file) == codec.encode(candidate))
        let replay = try await Diorama(file: file, scenarioID: "file-replay", mode: .replay, systems: system)
            .execute { wall in native.map { _ in wall.now } }
        #expect(replay.body == merged.effectiveDates)
        #expect(replay.report.disposition == .notRequested)
        #expect(source.count == native.count)
    }

    @Test
    func `invalid merged cumulative deltas refuse whole publication and preserve the previous document`() async throws {
        let large: Int64 = 5_000_000_000_000_000_000
        let original = try WallMergeFixtures.recording(
            origin: .observed(Date(timeIntervalSince1970: 0)),
            deltas: [.observed(0), .override(large), .observed(-large)], offset: 0)
        let codec = try WallMergeFixtures.codec()
        let attachment = try DioramaClockSystem.attachment(named: "clock", recording: original)
        let baseline = try ScenarioDefinition(attachments: [attachment])
        let bytes = try codec.encode(baseline)
        let file = try WallMergeFixtures.file(containing: bytes)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let native = [
            Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: Double(large) / 1000),
        ]
        let source = WallMergeFixtures.Source(native)
        let system = try DioramaClockSystem.instance(named: "clock") { source }
        let result = try await Diorama(file: file, scenarioID: "invalid-merge", mode: .record, systems: system)
            .execute { wall in native.map { _ in wall.now } }
        #expect(result.body == native)
        #expect(result.definition == nil)
        #expect(result.report.disposition == .refusedUnhealthy)
        #expect(result.report.preservation == .unchangedByThisRun)
        let issues = result.finalization.report.diagnostics.map(\.diagnostic.issue)
        #expect(issues == [.verification(.recordingMergeFailed)])
        #expect(result.report.issues.map(\.stage) == [.recording])
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try WallMergeFixtures.content(baseline) == original)
        #expect(source.count == native.count)
    }
}
