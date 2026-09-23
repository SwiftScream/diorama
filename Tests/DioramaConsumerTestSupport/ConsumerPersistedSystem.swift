import DioramaCore
import DioramaPersistence

/// A consumer-owned codec for the existing non-Codable semantic value.
public enum ConsumerPersistedSystem {
    /// Shared descriptor for independently keyed consumer instances.
    public static let type = ScenarioSystemType(
        "test.consumer-persisted",
        persistence: PersistentSystemRegistration(
            currentSchemaVersion: 1,
            payloadType: Payload.self,
            encode: { attachment in
                let trackID = trackID(for: attachment.id.key)
                guard attachment.trackIDs == [trackID],
                      let track = try? attachment.track(trackID, as: ConsumerStableValue.self)
                else {
                    throw PersistentSystemEncodingError.invalidTrackLayout(attachment.id)
                }
                return Payload(values: track.records.map(\.value.number))
            },
            decode: { payload, key in
                let attachmentID = attachmentID(for: key)
                let trackID = trackID(for: key)
                let preparation = ValuePreparation<ConsumerStableValue>()
                let values = try payload.values.enumerated().map { index, number in
                    try preparation.admitPrepared(
                        ConsumerStableValue(number),
                        context: .record(RecordIdentity(trackID: trackID, sequence: UInt64(index))))
                }
                return try ScenarioAttachment(id: attachmentID).adding(
                    SequentialTrack(id: trackID, values: values))
            }))

    /// Creates a public-only persistent consumer instance.
    public static func instance(key: AttachmentKey) throws -> ScenarioSystem<ConsumerSequentialDependency> {
        let trackID = trackID(for: key)
        let attachment = try ScenarioAttachment(id: attachmentID(for: key)).adding(
            SequentialTrack<ConsumerStableValue>(id: trackID))
        return try ScenarioSystem(type: type, attachment: attachment) { context in
            let preparation = ValuePreparation<ConsumerStableValue>()
            let lease = try context.lease(for: trackID, preparation: preparation)
            return PreparedSystem {
                ActivatedSystem(
                    dependency: ConsumerSequentialDependency(lease: lease, preparation: preparation),
                    deactivate: {})
            }
        }
    }

    /// Identity for one caller-selected attachment key.
    public static func attachmentID(for key: AttachmentKey) -> AttachmentID {
        AttachmentID(systemTypeID: type.id, key: key)
    }

    /// Identity for the consumer's only track.
    public static func trackID(for key: AttachmentKey) -> TrackID {
        TrackID(attachmentID: attachmentID(for: key), key: TrackKey(rawValue: "values"))
    }
}

private struct Payload: Codable, Sendable {
    let values: [Int]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case values
    }

    init(values: [Int]) {
        self.values = values
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        values = try container.decode([Int].self, forKey: .values)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(values, forKey: .values)
    }
}
