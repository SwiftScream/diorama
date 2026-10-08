import DioramaCore
import DioramaPersistence
import Foundation

/// Deliberate version-one schema for first-party wall observations.
enum DioramaDatePersistence {
    /// The only date payload schema version currently written and read.
    static let schemaVersion: UInt32 = 1

    /// The date system's current writer and strict reader.
    static let registration = PersistentSystemRegistration(
        currentSchemaVersion: schemaVersion,
        payloadType: WallPayload.self,
        encode: { attachment in
            do {
                return try WallPayload(recording: DioramaDateSystem.recording(in: attachment))
            } catch {
                throw PersistentSystemEncodingError.invalidTrackLayout(attachment.id)
            }
        },
        decode: { payload, key in
            try DioramaDateSystem.attachment(
                named: key.rawValue, recording: payload.recording())
        })
}

/// Safe payload validation failures that do not expose authored values.
enum WallSchemaError: Error, Equatable, Sendable {
    /// The effective origin cannot be read as an ISO 8601 instant.
    case invalidOrigin
    /// The effective delta does not use the accepted millisecond grammar.
    case invalidObservation(position: Int)
}

private struct WallPayload: Codable, Sendable {
    let origin: OverridableValue<String>?
    let observations: [OverridableValue<String>]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case origin
        case observations
    }

    init(recording: WallRecording) throws {
        if let recordedOrigin = recording.origin {
            let value = recordedOrigin.value
            guard let text = StableTimeCodec.formatOrigin(
                value.date, offsetMinutes: value.offsetMinutes)
            else { throw WallSchemaError.invalidOrigin }
            origin = recordedOrigin.map { _ in text }
        } else {
            origin = nil
        }
        observations = recording.observations.map { $0.map(StableTimeCodec.formatDuration) }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        origin = try container.contains(.origin)
            ? container.decode(OverridableValue<String>.self, forKey: .origin) : nil
        observations = try container.decode([OverridableValue<String>].self, forKey: .observations)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let origin {
            try container.encode(origin, forKey: .origin)
        }
        try container.encode(observations, forKey: .observations)
    }

    func recording() throws -> WallRecording {
        let semanticOrigin: OverridableValue<WallOrigin>? = if let origin {
            try origin.map { text in
                guard let value = StableTimeCodec.parseOrigin(text),
                      let wallOrigin = WallOrigin(date: value.date, offsetMinutes: value.offsetMinutes)
                else { throw WallSchemaError.invalidOrigin }
                return wallOrigin
            }
        } else {
            nil
        }
        let semanticObservations = try observations.enumerated().map { position, field in
            try field.map { text in
                guard let milliseconds = StableTimeCodec.parseDuration(text) else {
                    throw WallSchemaError.invalidObservation(position: position)
                }
                return milliseconds
            }
        }
        return try WallRecording(origin: semanticOrigin, observations: semanticObservations)
    }
}
