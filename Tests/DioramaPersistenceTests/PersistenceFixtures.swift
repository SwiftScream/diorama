import DioramaCore
import DioramaPersistence

extension PersistentSystemRegistryTests {
    static func numberRegistration(current: UInt32) -> PersistentSystemRegistration {
        PersistentSystemRegistration(
            systemTypeID: numberType,
            currentSchemaVersion: current,
            payloadType: NumberPayload.self,
            encode: { attachment in
                try NumberPayload(values: values(in: attachment, as: Int.self))
            },
            decode: { payload, key in
                try numberAttachment(key: key.rawValue, values: payload.values)
            })
    }

    static func labelRegistration(current: UInt32) -> PersistentSystemRegistration {
        PersistentSystemRegistration(
            systemTypeID: labelType,
            currentSchemaVersion: current,
            payloadType: LabelPayload.self,
            encode: { attachment in
                try LabelPayload(values: values(in: attachment, as: String.self))
            },
            decode: { payload, key in
                try labelAttachment(key: key.rawValue, values: payload.values)
            })
    }

    static func numberAttachment(key: String, values: [Int]) throws -> ScenarioAttachment {
        try attachment(systemTypeID: numberType, key: key, values: values)
    }

    static func labelAttachment(key: String, values: [String]) throws -> ScenarioAttachment {
        try attachment(systemTypeID: labelType, key: key, values: values)
    }

    static func nonCodableAttachment(
        key: String,
        values: [NonCodableValue]) throws -> ScenarioAttachment
    {
        try attachment(systemTypeID: nonPersistableType, key: key, values: values)
    }

    static func attachment(
        systemTypeID: SystemTypeID,
        key: String,
        values: [some Sendable]) throws -> ScenarioAttachment
    {
        let id = AttachmentID(
            systemTypeID: systemTypeID,
            key: AttachmentKey(rawValue: key))
        return try ScenarioAttachment(id: id).adding(
            SequentialTrack(
                id: TrackID(attachmentID: id, key: TrackKey(rawValue: "values")),
                values: prepared(values)))
    }

    static func numberID(key: String) -> AttachmentID {
        AttachmentID(
            systemTypeID: numberType,
            key: AttachmentKey(rawValue: key))
    }

    static func values<Value: Sendable>(
        in attachment: ScenarioAttachment,
        as type: Value.Type) throws -> [Value]
    {
        try requiredTrack(in: attachment, as: type).records.map(\.value)
    }

    static func requiredTrack<Value: Sendable>(
        in attachment: ScenarioAttachment,
        as type: Value.Type) throws -> SequentialTrack<Value>
    {
        let id = TrackID(
            attachmentID: attachment.id,
            key: TrackKey(rawValue: "values"))
        guard let track = try attachment.track(id, as: type) else {
            throw FixtureError.missingTrack
        }
        return track
    }

    static func prepared<Value: Sendable>(_ values: [Value]) throws -> [PreparedValue<Value>] {
        let definition = try ScenarioDefinition(
            id: ScenarioID(rawValue: "persistence-fixture"),
            defaultMode: .replay)
        let reporter = DiagnosticReporter(definition: definition)
        let preparation = ValuePreparation<Value>()
        return try values.map { value in
            try preparation.prepare(
                capturing: { value },
                purpose: .replay,
                reporter: reporter)
        }
    }
}
