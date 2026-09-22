import DioramaCore
import DioramaPersistence

/// The deliberate version-one persistence boundary for ``DioramaRandomSystem``.
public enum DioramaRandomPersistence {
    /// The only random payload schema version currently written and read.
    public static let schemaVersion: UInt32 = 1

    /// The first-party random system's current writer and reader.
    public static let registration = PersistentSystemRegistration(
        currentSchemaVersion: schemaVersion,
        payloadType: RandomPayload.self,
        encode: { attachment in
            let expectedTrackID = DioramaRandomSystem.trackID(for: attachment.id.key)
            guard attachment.trackIDs == [expectedTrackID],
                  let track = try? attachment.track(expectedTrackID, as: UInt64.self)
            else {
                throw PersistentSystemEncodingError.invalidTrackLayout(attachment.id)
            }
            return RandomPayload(values: track.records.map(\.value))
        },
        decode: { payload, key in
            try makeAttachment(key: key, values: payload.values)
        })
}

private struct RandomPayload: Codable, Sendable {
    let values: [UInt64]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case values
    }

    init(values: [UInt64]) {
        self.values = values
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        values = try container.decode([UInt64].self, forKey: .values)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(values, forKey: .values)
    }
}

private func makeAttachment(
    key: AttachmentKey,
    values: [UInt64]) throws -> ScenarioAttachment
{
    let attachmentID = DioramaRandomSystem.attachmentID(for: key)
    let trackID = DioramaRandomSystem.trackID(for: key)
    let preparation = ValuePreparation<UInt64>()
    let prepared = try values.enumerated().map { index, value in
        try preparation.admitPrepared(
            value,
            context: .record(
                RecordIdentity(
                    trackID: trackID,
                    sequence: UInt64(index))))
    }
    return try ScenarioAttachment(id: attachmentID).adding(
        SequentialTrack(id: trackID, values: prepared))
}
