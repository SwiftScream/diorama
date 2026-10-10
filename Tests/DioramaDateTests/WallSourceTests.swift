import DioramaCore
@testable import DioramaDate
import DioramaPersistence
import Foundation
import Synchronization
import Testing

struct WallSourceTests {
    @Test
    func `record returns native values and independently rounds absolute observations`() async throws {
        let base = 1_893_448_800.0
        let native = [0.00049, 0.00098, 0.00147, 0.00196].map {
            Date(timeIntervalSince1970: base + $0)
        }
        let probe = WallSourceProbe(values: native)
        let system = try DioramaDateSystem.instance(named: "wall") {
            probe.makeSource()
        }
        let zone = TimeZone.current
        let execution = try start(system)
        let wall = try execution.dependency(system)

        for expected in native {
            #expect(wall.now == expected)
        }
        let result = await execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        let definition = try #require(result.definition)
        let recording = try DioramaDateSystem.recording(in: definition.attachments[0])
        let rounded = try native.map { try #require(StableTimeCodec.roundedToMillisecond($0)) }
        #expect(recording.effectiveDates == rounded)
        #expect(recording.observations.map(\.value) == [0, 1, 0, 1])
        #expect(recording.origin?.value.offsetMinutes == zone.secondsFromGMT(for: native[0]) / 60)
        #expect(probe.readCount == native.count)
    }

    @Test
    func `first observation fixes the offset across a daylight saving transition`() async throws {
        let zone = try #require(TimeZone(identifier: "Australia/Sydney"))
        let before = try #require(StableTimeCodec.parseOrigin("2026-10-03T15:59:59.000Z")).date
        let after = before.addingTimeInterval(2)
        #expect(zone.secondsFromGMT(for: before) == 36000)
        #expect(zone.secondsFromGMT(for: after) == 39600)
        let probe = WallSourceProbe(values: [before, after, before])
        let system = try recordingSystem(named: "dst", timeZone: zone) {
            probe.makeSource()
        }
        let execution = try start(system)
        let wall = try execution.dependency(system)

        #expect(wall.now == before)
        #expect(wall.now == after)
        #expect(wall.now == before)
        let result = await execution.finish()
        let definition = try #require(result.definition)
        let recording = try DioramaDateSystem.recording(in: definition.attachments[0])
        #expect(recording.origin?.value.offsetMinutes == 600)
        #expect(recording.observations.map(\.value) == [0, 2000, -2000])
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test
    func `passthrough returns native values without changing a loaded wall track`() async throws {
        let original = try WallRecording(
            origin: .observed(#require(WallOrigin(
                date: Date(timeIntervalSince1970: 100), offsetMinutes: 60))),
            observations: [.observed(0), .observed(5000)])
        let attachment = try DioramaDateSystem.attachment(named: "wall", recording: original)
        let probe = WallSourceProbe(values: [Date(timeIntervalSince1970: 7.12345)])
        let system = try DioramaDateSystem.instance(named: "wall") { probe.makeSource() }
        let execution = try start(system, mode: .passthrough, attachment: attachment)
        let wall = try execution.dependency(system)

        #expect(wall.now == Date(timeIntervalSince1970: 7.12345))
        let result = await execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(try DioramaDateSystem.recording(in: #require(result.definition).attachments[0]) == original)
        #expect(probe.readCount == 1)
    }

    @Test(arguments: [false, true])
    func `recording no reads replaces a nonempty baseline with an empty wall track`(overridden: Bool) async throws {
        let origin = try #require(WallOrigin(date: Date(timeIntervalSince1970: 100), offsetMinutes: 60))
        let original = try WallRecording(
            origin: overridden ? .override(origin) : .observed(origin),
            observations: [.observed(0)])
        let attachment = try DioramaDateSystem.attachment(named: "wall", recording: original)
        let probe = WallSourceProbe(values: [])
        let system = try DioramaDateSystem.instance(named: "wall") { probe.makeSource() }
        let execution = try start(system, attachment: attachment)

        let result = await execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(try DioramaDateSystem.recording(in: #require(result.definition).attachments[0]) == .empty)
        #expect(probe.readCount == 0)
    }

    @Test
    func `named clocks retain independent live sequences`() async throws {
        let firstProbe = WallSourceProbe(values: [Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2)])
        let secondProbe = WallSourceProbe(values: [Date(timeIntervalSince1970: 10)])
        let first = try DioramaDateSystem.instance(named: "first") {
            firstProbe.makeSource()
        }
        let second = try DioramaDateSystem.instance(named: "second") {
            secondProbe.makeSource()
        }
        let definition = try ScenarioDefinition(attachments: [first.attachment, second.attachment])
        let execution = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "date-independent"),
            defaultMode: .record, systems: [AnyScenarioSystem(second), AnyScenarioSystem(first)])
        let firstWall = try execution.dependency(first)
        let secondWall = try execution.dependency(second)

        #expect(secondWall.now == Date(timeIntervalSince1970: 10))
        #expect(firstWall.now == Date(timeIntervalSince1970: 1))
        #expect(firstWall.now == Date(timeIntervalSince1970: 2))
        let result = await execution.finish()
        let recorded = try #require(result.definition)
        #expect(try DioramaDateSystem.recording(in: recorded.attachments[0]).effectiveDates == [
            Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 2),
        ])
        #expect(try DioramaDateSystem.recording(in: recorded.attachments[1]).effectiveDates == [
            Date(timeIntervalSince1970: 10),
        ])
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test
    func `source factory creates a new live source for each execution`() async throws {
        let probe = WallSourceProbe(values: [
            Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 1),
        ])
        let system = try DioramaDateSystem.instance(named: "fresh") {
            probe.makeSource()
        }

        let first = try start(system)
        #expect(try first.dependency(system).now == Date(timeIntervalSince1970: 1))
        _ = await first.finish()
        let second = try start(system)
        #expect(try second.dependency(system).now == Date(timeIntervalSince1970: 1))
        _ = await second.finish()

        #expect(probe.creationCount == 2)
        #expect(probe.releaseCount == 2)
    }

    @Test
    func `concurrent callers record in source order without overlapping source calls`() async throws {
        let native = (0..<64).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let probe = WallSourceProbe(values: native, delay: 0.001)
        let system = try DioramaDateSystem.instance(named: "concurrent") {
            probe.makeSource()
        }
        let execution = try start(system)
        let wall = try execution.dependency(system)
        let returned = await withTaskGroup(of: Date.self, returning: [Date].self) { group in
            for _ in native {
                group.addTask { wall.now }
            }
            var result: [Date] = []
            for await date in group {
                result.append(date)
            }
            return result
        }

        #expect(returned.sorted() == native)
        let result = await execution.finish()
        let recorded = try #require(result.definition)
        #expect(try DioramaDateSystem.recording(in: recorded.attachments[0]).effectiveDates == native)
        #expect(probe.maximumConcurrentReads == 1)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test
    func `preparation failure preserves the live return and invalidates the candidate`() async throws {
        let invalid = Date(timeIntervalSince1970: .infinity)
        let probe = WallSourceProbe(values: [invalid])
        let system = try DioramaDateSystem.instance(named: "invalid") {
            probe.makeSource()
        }
        let execution = try start(system)
        let wall = try execution.dependency(system)

        #expect(wall.now.timeIntervalSince1970.isInfinite)
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.conversionFailed])
        #expect(probe.readCount == 1)
    }

    @Test
    func `finish detaches the source from an escaped wall handle`() async throws {
        let date = Date(timeIntervalSince1970: 17)
        let probe = WallSourceProbe(values: [date])
        let system = try DioramaDateSystem.instance(named: "closed") {
            probe.makeSource()
        }
        let execution = try start(system)
        let wall = try execution.dependency(system)
        #expect(wall.now == date)
        #expect(probe.releaseCount == 0)

        _ = await execution.finish()
        #expect(probe.releaseCount == 1)
        #expect(wall.now == date)
        #expect(probe.readCount == 1)
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.leaseClosed),
        ])
    }

    @Test
    func `rerecord replaces an ordinary baseline offset with the current zone offset`() async throws {
        let date = try #require(StableTimeCodec.parseOrigin("2030-01-01T00:00:00.000Z")).date
        let offset = TimeZone.current.secondsFromGMT(for: date) / 60
        let oldOffset = offset == 0 ? 60 : 0
        let original = try WallRecording(
            origin: .observed(#require(WallOrigin(date: date, offsetMinutes: oldOffset))),
            observations: [.observed(0)])
        let attachment = try DioramaDateSystem.attachment(named: "fresh-zone", recording: original)
        let probe = WallSourceProbe(values: [date.addingTimeInterval(1)])
        let system = try DioramaDateSystem.instance(named: "fresh-zone") { probe.makeSource() }
        let execution = try start(system, attachment: attachment)

        #expect(try execution.dependency(system).now == date.addingTimeInterval(1))
        let result = await execution.finish()
        let recording = try DioramaDateSystem.recording(in: #require(result.definition).attachments[0])
        #expect(recording.origin?.value.offsetMinutes == offset)
        #expect(recording.origin?.value.date == date.addingTimeInterval(1))
        #expect(recording.origin?.isOverride == false)
        #expect(try DioramaDateSystem.recording(in: attachment) == original)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test
    func `unrepresentable offset preserves the native return and invalidates recording`() async throws {
        let zone = try #require(TimeZone(secondsFromGMT: 30))
        let date = Date(timeIntervalSince1970: 100)
        let probe = WallSourceProbe(values: [date])
        let system = try recordingSystem(named: "subminute", timeZone: zone) { probe.makeSource() }
        let execution = try start(system)

        #expect(try execution.dependency(system).now == date)
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.conversionFailed])
        #expect(probe.readCount == 1)
    }

    /// Exercise recording with a controlled zone without changing process-wide defaults.
    private func recordingSystem(
        named name: String, timeZone: TimeZone,
        sourceFactory: @escaping @Sendable () -> some DioramaDateSource)
        throws -> ScenarioSystem<any DioramaDateSource>
    {
        let attachment = try DioramaDateSystem.attachment(named: name)
        let trackID = DioramaDateSystem.trackID(for: attachment.id.key)
        return try ScenarioSystem(type: DioramaDateSystem.type, attachment: attachment) { context in
            let lease = try context.lease(
                for: trackID, preparation: ValuePreparation<OverridableValue<Date>>(),
                headerPreparation: ValuePreparation<Int?>())
            return PreparedSystem {
                let clock = LiveDateSource(
                    mode: .record(WallRecordingState(timeZone: timeZone)),
                    lease: lease, source: sourceFactory())
                return ActivatedSystem(dependency: clock as any DioramaDateSource, deactivate: { clock.close() })
            }
        }
    }

    private func start(
        _ system: ScenarioSystem<any DioramaDateSource>,
        mode: ScenarioMode = .record,
        attachment: ScenarioAttachment? = nil) throws -> ScenarioExecution
    {
        let definition = try ScenarioDefinition(attachments: [attachment ?? system.attachment])
        return try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "date-test"),
            defaultMode: mode, systems: [AnyScenarioSystem(system)])
    }
}

extension WallSourceTests {
    @Test(arguments: [ScenarioMode.record, .passthrough])
    func `default source returns live wall dates and honors the selected mode`(mode: ScenarioMode) async throws {
        let system = try DioramaDateSystem.instance(named: "platform-wall")
        let execution = try start(system, mode: mode)
        let wall = try execution.dependency(system)
        let before = Date()
        let observed = wall.now
        let after = Date()

        #expect(observed >= before)
        #expect(observed <= after)
        let result = await execution.finish()
        let recording = try DioramaDateSystem.recording(in: #require(result.definition).attachments[0])
        if mode == .record {
            #expect(try recording.effectiveDates == [#require(StableTimeCodec.roundedToMillisecond(observed))])
        } else {
            #expect(recording == .empty)
        }
        #expect(result.report.diagnostics.isEmpty)
        #expect(wall.now == observed)
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.leaseClosed),
        ])
    }

    @Test(arguments: [([0.0, 1e16], 1), ([0.0, 2e15, 1e16], 2)])
    func `out of range observations preserve native returns and last value`(
        seconds: [TimeInterval], failures: Int) async throws
    {
        // Both extreme values now fail the portable Date range before delta
        // arithmetic. Each unsupported read retains its own conversion fact.
        let native = seconds.map { Date(timeIntervalSince1970: $0) }
        let probe = WallSourceProbe(values: native)
        let system = try recordingSystem(named: "overflow", timeZone: .gmt) { probe.makeSource() }
        let execution = try start(system)
        let wall = try execution.dependency(system)

        for date in native {
            #expect(wall.now == date)
        }
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue)
            == Array(repeating: .conversionFailed, count: failures))
        #expect(probe.readCount == native.count)
        #expect(probe.releaseCount == 1)
        #expect(wall.now == native.last)
        #expect(probe.readCount == native.count)
    }

    @Test(arguments: [ScenarioMode.record, .passthrough])
    func `closing before the first wall read returns the epoch without accessing the source`(
        mode: ScenarioMode) async throws
    {
        let probe = WallSourceProbe(values: [])
        let system = try DioramaDateSystem.instance(named: "unread") { probe.makeSource() }
        let execution = try start(system, mode: mode)
        let wall = try execution.dependency(system)

        let result = await execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(probe.releaseCount == 1)
        #expect(wall.now == Date(timeIntervalSince1970: 0))
        #expect(probe.readCount == 0)
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.leaseClosed),
        ])
    }
}

private final class WallSourceProbe: Sendable {
    private struct State: Sendable {
        var next = 0
        var creationCount = 0
        var readCount = 0
        var concurrentReads = 0
        var maximumConcurrentReads = 0
        var releaseCount = 0
    }

    private let values: [Date]
    private let delay: TimeInterval
    private let state = Mutex(State())

    init(values: [Date], delay: TimeInterval = 0) {
        self.values = values
        self.delay = delay
    }

    var readCount: Int {
        state.withLock { $0.readCount }
    }

    var creationCount: Int {
        state.withLock { $0.creationCount }
    }

    var maximumConcurrentReads: Int {
        state.withLock { $0.maximumConcurrentReads }
    }

    var releaseCount: Int {
        state.withLock { $0.releaseCount }
    }

    func makeSource() -> ProbedWallSource {
        state.withLock { $0.creationCount += 1 }
        return ProbedWallSource(probe: self)
    }

    func read() -> Date {
        let date = state.withLock { state in
            let date = values[state.next]
            state.next += 1
            state.readCount += 1
            state.concurrentReads += 1
            state.maximumConcurrentReads = max(state.maximumConcurrentReads, state.concurrentReads)
            return date
        }
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        state.withLock { $0.concurrentReads -= 1 }
        return date
    }

    func released() {
        state.withLock { $0.releaseCount += 1 }
    }
}

private final class ProbedWallSource: DioramaDateSource {
    private let probe: WallSourceProbe

    init(probe: WallSourceProbe) {
        self.probe = probe
    }

    var now: Date {
        probe.read()
    }

    deinit { probe.released() }
}
