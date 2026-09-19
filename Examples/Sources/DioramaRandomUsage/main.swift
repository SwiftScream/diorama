import DioramaCore
import DioramaRandom

@main
struct DioramaRandomUsage {
    static func main() async throws {
        let randomKey = AttachmentKey(rawValue: "example-random")
        let recordingSystem = try DioramaRandomSystem.instance(for: randomKey)
        let recordingDefinitionConfiguration = ScenarioConfiguration(
            id: ScenarioID(rawValue: "random-recording-example"),
            defaultMode: .record)
        let recordingDefinition = try ScenarioDefinition(attachments: [recordingSystem.attachment])

        let recording = try await recordingDefinition.execute(
            configuration: recordingDefinitionConfiguration,
            with: recordingSystem)
        { generator in
            var generator = generator
            return Array(0..<5).map { _ in
                generator.next()
            }
        }
        let recordedValues = recording.body.get()
        try requireCleanFinalization(recording.finalization)

        let replaySystem = try DioramaRandomSystem.instance(for: randomKey)
        let replayDefinition = try makeReplayDefinition(
            randomKey: randomKey,
            values: recordedValues)
        let replayDefinitionConfiguration = ScenarioConfiguration(
            id: ScenarioID(rawValue: "random-replay-example"),
            defaultMode: .replay)
        let replay = try await replayDefinition.execute(
            configuration: replayDefinitionConfiguration,
            with: replaySystem)
        { generator in
            var generator = generator
            return Array(0..<5).map { _ in
                generator.next()
            }
        }
        let replayedValues = replay.body.get()
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
