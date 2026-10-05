@testable import DioramaClock
import DioramaCore
import Foundation
import Synchronization
import Testing

struct WallReplayTests {
    @Test
    func `replay returns prepared dated observations including repeats and backward movement`() async throws {
        let original = try recording([100, 105, 105, 98, 100])
        let attachment = try DioramaClockSystem.attachment(named: "wall", recording: original)
        let factory = ReplaySourceFactoryProbe()
        let system = try DioramaClockSystem.instance(named: "wall") {
            factory.makeSource()
        }
        let execution = try start(system, attachment: attachment)
        let wall = try execution.dependency(system)

        #expect((0..<5).map { _ in wall.now } == original.effectiveDates)
        let result = await execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.usage[0].tracks[0].activity == .replay(claimedCount: 5, unclaimedCount: 0))
        #expect(result.usage[0].tracks[0].claimedRecords.count == 5)
        for claim in result.usage[0].tracks[0].claimedRecords {
            #expect(claim.isConsumed)
        }
        #expect(result.evaluate(.allRecordsClaimed).isSatisfied)
        #expect(result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(factory.creationCount == 0)
    }

    @Test
    func `exhaustion reports and repeats the last replayed value`() async throws {
        let original = try recording([100, 105, 98])
        let attachment = try DioramaClockSystem.attachment(named: "wall", recording: original)
        let factory = ReplaySourceFactoryProbe()
        let system = try DioramaClockSystem.instance(named: "wall") {
            factory.makeSource()
        }
        let execution = try start(system, attachment: attachment)
        let wall = try execution.dependency(system)

        #expect((0..<4).map { _ in wall.now } == [
            Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 105),
            Date(timeIntervalSince1970: 98), Date(timeIntervalSince1970: 98),
        ])
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.replayExhausted(availableCount: 3)),
        ])
        #expect(result.usage[0].tracks[0].activity == .replay(claimedCount: 3, unclaimedCount: 0))
        #expect(factory.creationCount == 0)
    }

    @Test
    func `empty replay diagnoses exhaustion and uses the Unix epoch`() async throws {
        let attachment = try DioramaClockSystem.attachment(named: "wall")
        let factory = ReplaySourceFactoryProbe()
        let system = try DioramaClockSystem.instance(named: "wall") {
            factory.makeSource()
        }
        let execution = try start(system, attachment: attachment)
        let wall = try execution.dependency(system)

        #expect(wall.now == Date(timeIntervalSince1970: 0))
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.replayExhausted(availableCount: 0)),
        ])
        #expect(result.usage[0].tracks[0].activity == .replay(claimedCount: 0, unclaimedCount: 0))
        #expect(factory.creationCount == 0)
    }

    @Test
    func `a missing replay track fails startup while an empty track is valid`() async throws {
        let factory = ReplaySourceFactoryProbe()
        let system = try DioramaClockSystem.instance(named: "wall") {
            factory.makeSource()
        }
        let missing = ScenarioAttachment(id: system.attachment.id)
        do {
            _ = try ScenarioExecution.start(
                definition: ScenarioDefinition(attachments: [missing]),
                scenarioID: ScenarioID(rawValue: "clock-missing"), defaultMode: .replay,
                systems: [AnyScenarioSystem(system)])
            Issue.record("A replay attachment missing its named wall track must fail startup")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.report.diagnostics.contains {
                $0.diagnostic.issue == .lifecycle(.preparationFailed)
            })
        }
        #expect(factory.creationCount == 0)

        let emptySystem = try DioramaClockSystem.instance(named: "empty") {
            factory.makeSource()
        }
        let emptyAttachment = try DioramaClockSystem.attachment(named: "empty")
        let execution = try start(emptySystem, attachment: emptyAttachment)
        #expect(try execution.dependency(emptySystem).now == Date(timeIntervalSince1970: 0))
        _ = await execution.finish()
    }

    @Test
    func `keyed replay cursors consume independent recordings`() async throws {
        let firstRecording = try recording([1, 2])
        let secondRecording = try recording([10, 20, 30])
        let firstAttachment = try DioramaClockSystem.attachment(named: "first", recording: firstRecording)
        let secondAttachment = try DioramaClockSystem.attachment(named: "second", recording: secondRecording)
        let factory = ReplaySourceFactoryProbe()
        let first = try DioramaClockSystem.instance(named: "first") { factory.makeSource() }
        let second = try DioramaClockSystem.instance(named: "second") { factory.makeSource() }
        let definition = try ScenarioDefinition(attachments: [firstAttachment, secondAttachment])
        let execution = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "clock-keyed"),
            defaultMode: .replay, systems: [AnyScenarioSystem(second), AnyScenarioSystem(first)])
        let firstClock = try execution.dependency(first)
        let secondClock = try execution.dependency(second)

        #expect(firstClock.now == Date(timeIntervalSince1970: 1))
        #expect(secondClock.now == Date(timeIntervalSince1970: 10))
        #expect(firstClock.now == Date(timeIntervalSince1970: 2))
        #expect(secondClock.now == Date(timeIntervalSince1970: 20))
        let result = await execution.finish()
        #expect(result.usage.map { $0.tracks[0].activity } == [
            .replay(claimedCount: 2, unclaimedCount: 0), .replay(claimedCount: 2, unclaimedCount: 1),
        ])
        let unclaimed = result.usage[1].tracks[0].unclaimedRecords
        #expect(unclaimed == [RecordIdentity(trackID: secondAttachment.trackIDs[0], sequence: 2)])
        #expect(result.evaluate(.allRecordsClaimed).failures == unclaimed.map { .unclaimedRecord($0) })
        #expect(result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(factory.creationCount == 0)
    }

    @Test
    func `concurrent replay claims each observation once without consulting the source`() async throws {
        let values = (0..<80).map { TimeInterval($0) }
        let original = try recording(values)
        let attachment = try DioramaClockSystem.attachment(named: "concurrent", recording: original)
        let factory = ReplaySourceFactoryProbe()
        let system = try DioramaClockSystem.instance(named: "concurrent") {
            factory.makeSource()
        }
        let execution = try start(system, attachment: attachment)
        let wall = try execution.dependency(system)
        let returned = await withTaskGroup(of: Date.self, returning: [Date].self) { group in
            for _ in 0..<100 {
                group.addTask { wall.now }
            }
            var dates: [Date] = []
            for await date in group {
                dates.append(date)
            }
            return dates
        }

        #expect(returned.count == 100)
        #expect(returned.sorted() == (original.effectiveDates + Array(
            repeating: Date(timeIntervalSince1970: 79), count: 20)).sorted())
        let result = await execution.finish()
        #expect(result.usage[0].tracks[0].activity == .replay(claimedCount: 80, unclaimedCount: 0))
        #expect(result.report.diagnostics.count == 20)
        #expect(result.report.diagnostics.allSatisfy {
            $0.diagnostic.issue == .sequential(.replayExhausted(availableCount: 80))
        })
        #expect(factory.creationCount == 0)
    }

    @Test
    func `escaped replay handle repeats its last value after finish`() async throws {
        let original = try recording([1, 2])
        let attachment = try DioramaClockSystem.attachment(named: "closed", recording: original)
        let factory = ReplaySourceFactoryProbe()
        let system = try DioramaClockSystem.instance(named: "closed") {
            factory.makeSource()
        }
        let execution = try start(system, attachment: attachment)
        let wall = try execution.dependency(system)
        #expect(wall.now == Date(timeIntervalSince1970: 1))

        _ = await execution.finish()
        #expect(wall.now == Date(timeIntervalSince1970: 1))
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.leaseClosed),
        ])
        #expect(factory.creationCount == 0)
    }

    @Test
    func `replay returns effective dates and preserves stored authorship`() async throws {
        let values: [OverridableValue<Date>] = [
            .override(Date(timeIntervalSince1970: 100)),
            .observed(Date(timeIntervalSince1970: 105)),
            .override(Date(timeIntervalSince1970: 98)),
        ]
        let original = try WallRecording(offsetMinutes: 0, values: values)
        let attachment = try DioramaClockSystem.attachment(named: "authored", recording: original)
        let system = try DioramaClockSystem.instance(named: "authored")
        let execution = try start(system, attachment: attachment)
        let wall = try execution.dependency(system)
        #expect((0..<3).map { _ in wall.now } == values.map(\.value))
        let result = await execution.finish()
        let definition = try #require(result.definition)
        let stored = try DioramaClockSystem.recording(in: definition.attachments[0])
        #expect(stored.effectiveValues == values)
        #expect(wall.now == values[2].value)
    }

    @Test
    func `closing an unread replay uses the epoch rather than an unconsumed date`() async throws {
        let original = try recording([100, 105])
        let attachment = try DioramaClockSystem.attachment(named: "unread", recording: original)
        let system = try DioramaClockSystem.instance(named: "unread")
        let execution = try start(system, attachment: attachment)
        let wall = try execution.dependency(system)
        let result = await execution.finish()
        #expect(wall.now == Date(timeIntervalSince1970: 0))
        #expect(result.usage[0].tracks[0].unclaimedRecords.count == 2)
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
    }

    @Test
    func `escaped passthrough handle repeats its last value after finish`() async throws {
        let original = try recording([1, 2])
        let attachment = try DioramaClockSystem.attachment(named: "passthrough", recording: original)
        let factory = ReplaySourceFactoryProbe()
        let system = try DioramaClockSystem.instance(named: "passthrough") {
            factory.makeSource()
        }
        let execution = try start(system, attachment: attachment, mode: .passthrough)
        let wall = try execution.dependency(system)
        let native = Date(timeIntervalSince1970: 999)
        #expect(wall.now == native)

        _ = await execution.finish()
        #expect(wall.now == native)
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.leaseClosed),
        ])
        #expect(factory.creationCount == 1)
    }

    private func start(
        _ system: ScenarioSystem<any DioramaWallClock>,
        attachment: ScenarioAttachment,
        mode: ScenarioMode = .replay) throws -> ScenarioExecution
    {
        try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]),
            scenarioID: ScenarioID(rawValue: "clock-replay"), defaultMode: mode,
            systems: [AnyScenarioSystem(system)])
    }

    private func recording(_ seconds: [TimeInterval]) throws -> WallRecording {
        try WallRecording(
            offsetMinutes: 0,
            values: seconds.map { .observed(Date(timeIntervalSince1970: $0)) })
    }
}

private final class ReplaySourceFactoryProbe: Sendable {
    private let creations = Mutex(0)

    var creationCount: Int {
        creations.withLock { $0 }
    }

    func makeSource() -> ReplayWallSource {
        creations.withLock { $0 += 1 }
        return ReplayWallSource()
    }
}

private struct ReplayWallSource: DioramaWallClock {
    var now: Date {
        Date(timeIntervalSince1970: 999)
    }
}
