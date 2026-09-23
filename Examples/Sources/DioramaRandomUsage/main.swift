import Diorama
import DioramaCore
import DioramaRandom
import Foundation

@main
struct DioramaRandomUsage {
    static func main() async throws {
        let random = try DioramaRandomSystem.instance(named: "example-random")

        let recordingSetup = try Diorama(scenarioID: "random-recording-example", mode: .record, systems: random)
        let recording = try await recordingSetup.execute { generator in
            var generator = generator
            return Array(0..<5).map { _ in
                generator.next()
            }
        }
        let recordedValues = recording.body
        try requireCleanFinalization(recording.finalization)

        guard let replayDefinition = recording.definition else { throw ExampleError.unavailableDefinition }

        let replaySetup = try Diorama(
            definition: replayDefinition, scenarioID: "random-replay-example", mode: .replay, systems: random)
        let replay = try await replaySetup.execute { generator in
            var generator = generator
            return Array(0..<5).map { _ in
                generator.next()
            }
        }
        let replayedValues = replay.body
        try requireCleanFinalization(replay.finalization)
        guard recordedValues == replayedValues else { throw ExampleError.replayMismatch }

        print("recorded: \(recordedValues)")
        print("replayed: \(replayedValues)")
        try await demonstrateFileWorkflow(random: random)
    }

    private static func demonstrateFileWorkflow(
        random: ScenarioSystem<any RandomNumberGenerator & Sendable>) async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("random.json")
        let recording = try await Diorama(file: file, scenarioID: "file-record", mode: .record, systems: random)
            .execute { generator in
                var generator = generator
                return generator.next()
            }
        try requireCleanFinalization(recording.finalization)
        guard case .published = recording.publication else { throw ExampleError.publicationFailed }
        let replay = try await Diorama(file: file, scenarioID: "file-replay", mode: .replay, systems: random)
            .execute { generator in
                var generator = generator
                return generator.next()
            }
        try requireCleanFinalization(replay.finalization)
        guard replay.body == recording.body else { throw ExampleError.replayMismatch }
        guard case .notRequested = replay.publication else { throw ExampleError.unexpectedPublication }
        print("file replay: \(replay.body)")
    }

    private static func requireCleanFinalization(
        _ finalization: ScenarioFinalizationResult) throws
    {
        guard finalization.report.diagnostics.isEmpty else {
            throw ExampleError.unexpectedDiagnostics
        }
    }
}

private enum ExampleError: Error {
    case unexpectedDiagnostics
    case unavailableDefinition
    case publicationFailed
    case replayMismatch
    case unexpectedPublication
}
