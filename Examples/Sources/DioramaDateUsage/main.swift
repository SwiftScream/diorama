import Diorama
import DioramaDate
import Foundation
import Synchronization

@main
struct DioramaDateUsage {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("date.json")
        let source = ExampleWallSource()
        let wall = try DioramaDateSystem.instance(named: "device-wall") { source }

        let recording = try await Diorama(file: file, scenarioID: "date-record", mode: .record, systems: wall)
            .execute { context, wall in
                try await observationsAcrossRetry(wall: wall, clock: context.clock)
            }
        guard recording.report.disposition == .published,
              recording.report.diagnostics.isEmpty else { throw ExampleError.recordingFailed }
        let bytes = try Data(contentsOf: file)
        let replay = try await Diorama(file: file, scenarioID: "date-replay", mode: .replay, systems: wall)
            .execute { context, wall in
                try await observationsAcrossRetry(wall: wall, clock: context.clock)
            }
        guard replay.body == recording.body, source.readCount == 2,
              replay.report.diagnostics.isEmpty,
              replay.report.disposition == .notRequested,
              replay.finalization.evaluate(.allRecordsClaimed).isSatisfied,
              replay.finalization.evaluate(.allClaimedRecordsConsumed).isSatisfied,
              try Data(contentsOf: file) == bytes else { throw ExampleError.replayMismatch }
        print("wall observations replayed: \(replay.body.map { $0.ISO8601Format() })")

        let clockOnly = try await Diorama(scenarioID: "retry-without-wall", mode: .record)
            .execute { context in
                try await context.clock.sleep(for: .milliseconds(2))
            }
        guard clockOnly.definition?.attachments.isEmpty == true,
              clockOnly.finalization.usage.isEmpty,
              clockOnly.report.diagnostics.isEmpty else { throw ExampleError.unexpectedClockContent }
        print("retry delay also works without a wall attachment")
    }

    /// Application code accepts the standard Clock protocol for retry delays.
    /// A wall adjustment changes observed dates while elapsed time moves forward.
    private static func observationsAcrossRetry<C: Clock>(wall: any DioramaDateSource, clock: C)
        async throws -> [Date] where C.Duration == Duration
    {
        let first = wall.now
        let before = clock.now
        try await clock.sleep(for: .milliseconds(2))
        guard before < clock.now else { throw ExampleError.clockDidNotAdvance }
        return [first, wall.now]
    }
}

private final class ExampleWallSource: DioramaDateSource {
    private let position = Mutex(0)

    var readCount: Int {
        position.withLock { $0 }
    }

    var now: Date {
        position.withLock { index in
            defer { index += 1 }
            precondition(index < 2, "Replay must not read the live source")
            return Date(timeIntervalSince1970: index == 0 ? 1_893_456_000 : 1_893_455_995)
        }
    }
}

private enum ExampleError: Error {
    case recordingFailed
    case replayMismatch
    case unexpectedClockContent
    case clockDidNotAdvance
}
