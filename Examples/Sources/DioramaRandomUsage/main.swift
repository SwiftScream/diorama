import Diorama
import DioramaCore
import DioramaRandom

@main
struct DioramaRandomUsage {
    static func main() async throws {
        let randomKey = AttachmentKey(rawValue: "example-random")
        let random = try DioramaRandomSystem.instance(for: randomKey)

        let recordingSetup = try Diorama(scenarioID: "random-recording-example", mode: .record, systems: random)
        let recording = try await recordingSetup.execute { generator in
            var generator = generator
            return Array(0..<5).map { _ in
                generator.next()
            }
        }
        let recordedValues = recording.body
        try requireCleanFinalization(recording.finalization)

        // Candidate extraction is a later unit; construct the baseline explicitly.
        let replayDefinition = try makeReplayDefinition(
            randomKey: randomKey,
            values: recordedValues)

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

        print("recorded: \(recordedValues)")
        print("replayed: \(replayedValues)")
    }

    private static func makeReplayDefinition(
        randomKey: AttachmentKey,
        values: [UInt64]) throws -> ScenarioDefinition
    {
        let preparationDefinition = try ScenarioDefinition()
        let reporter = DiagnosticReporter(
            scenarioID: ScenarioID(rawValue: "random-replay-preparation-example"),
            definition: preparationDefinition)
        let preparation = ValuePreparation<UInt64>()
        let preparedValues = try values.map { value in
            try preparation.prepare(
                capturing: { value },
                purpose: .replay,
                reporter: reporter)
        }
        let attachmentID = DioramaRandomSystem.attachmentID(for: randomKey)
        let attachment = try ScenarioAttachment(id: attachmentID).adding(
            SequentialTrack(
                id: DioramaRandomSystem.trackID(for: randomKey),
                values: preparedValues))
        return try ScenarioDefinition(attachments: [attachment])
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
}
