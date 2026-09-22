import Diorama
import DioramaCore
import Synchronization

enum DioramaFixtures {
    static let type = ScenarioSystemType("consumer")

    final class Journal: Sendable {
        let events = Mutex<[String]>([])
    }

    static func attachment(_ key: String) -> AttachmentID {
        AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: key))
    }

    static func track(_ key: String) -> TrackID {
        TrackID(attachmentID: attachment(key), key: TrackKey(rawValue: "values"))
    }

    static func definition(_ keys: [String]) throws -> ScenarioDefinition {
        try ScenarioDefinition(attachments: keys.map { key in
            try ScenarioAttachment(id: attachment(key)).adding(
                SequentialTrack(id: track(key), values: preparedValues([1, 2])))
        })
    }
}

func preparedValues<Value: Sendable>(_ values: [Value]) throws -> [PreparedValue<Value>] {
    let reporter = try DiagnosticReporter(
        scenarioID: ScenarioID(rawValue: "fixtures"), definition: ScenarioDefinition())
    let preparation = ValuePreparation<Value>()
    return try values.map { value in
        try preparation.prepare(capturing: { value }, purpose: .replay, reporter: reporter)
    }
}
