import DioramaCore
import Foundation

/// The format-neutral versioned object model shared by persistence transports.
struct PersistedScenarioEnvelope: Codable {
    let scenario: ScenarioDefinition

    enum CodingKeys: String, CodingKey, CaseIterable {
        case diorama
        case systems
    }

    init(_ scenario: ScenarioDefinition) {
        self.scenario = scenario
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        _ = try container.decode(PersistedScenarioHeader.self, forKey: .diorama)
        let systems = try container.decode([PersistedSystemEntry].self, forKey: .systems)
        scenario = try ScenarioDefinition(attachments: systems.map(\.attachment))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(PersistedScenarioHeader(), forKey: .diorama)
        try container.encode(
            scenario.attachments.map(PersistedSystemEntry.init),
            forKey: .systems)
    }
}

private struct PersistedScenarioHeader: Codable {
    let schemaVersion: UInt32

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
    }

    init() {
        schemaVersion = JSONScenarioCodec.schemaVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        schemaVersion = try decodeSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            codingPath: decoder.codingPath)
        guard schemaVersion == JSONScenarioCodec.schemaVersion else {
            throw PersistedScenarioCodingError.unsupportedEnvelopeVersion(
                declared: schemaVersion,
                supported: [JSONScenarioCodec.schemaVersion])
        }
    }
}

private struct PersistedSystemEntry: Codable {
    let attachment: ScenarioAttachment

    enum CodingKeys: String, CodingKey, CaseIterable {
        case attachmentKey
        case payload
        case schemaVersion
        case type
    }

    init(_ attachment: ScenarioAttachment) {
        self.attachment = attachment
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        let attachmentKey = try AttachmentKey(
            rawValue: container.decode(String.self, forKey: .attachmentKey))
        let systemTypeID = try SystemTypeID(
            rawValue: container.decode(String.self, forKey: .type))
        let schemaVersion = try decodeSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            codingPath: decoder.codingPath)
        attachment = try decoder.persistentSystemRegistry.decode(
            PersistedSystemDescriptor(
                attachmentKey: attachmentKey,
                systemTypeID: systemTypeID,
                schemaVersion: schemaVersion),
            from: container.superDecoder(forKey: .payload))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let descriptor = try encoder.persistentSystemRegistry.encode(
            attachment,
            to: container.superEncoder(forKey: .payload))
        try container.encode(descriptor.attachmentKey.rawValue, forKey: .attachmentKey)
        try container.encode(descriptor.schemaVersion, forKey: .schemaVersion)
        try container.encode(descriptor.systemTypeID.rawValue, forKey: .type)
    }
}

private func decodeSchemaVersion<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key,
    codingPath: [any CodingKey]) throws -> UInt32
{
    let error = PersistedScenarioCodingError.malformed(
        codingPath: persistedCodingPath(codingPath) + [key.stringValue])
    let rawValue: Int64
    do {
        rawValue = try container.decode(Int64.self, forKey: key)
    } catch is DecodingError {
        throw error
    }
    guard let version = UInt32(exactly: rawValue) else {
        throw error
    }
    return version
}

private extension Encoder {
    var persistentSystemRegistry: PersistentSystemRegistry {
        get throws {
            guard let registry = userInfo[persistentSystemRegistryUserInfoKey]
                as? PersistentSystemRegistry
            else {
                throw EncodingError.invalidValue(
                    ScenarioDefinition.self,
                    .init(
                        codingPath: codingPath,
                        debugDescription: "Missing internal persistent-system registry"))
            }
            return registry
        }
    }
}

private extension Decoder {
    var persistentSystemRegistry: PersistentSystemRegistry {
        get throws {
            guard let registry = userInfo[persistentSystemRegistryUserInfoKey]
                as? PersistentSystemRegistry
            else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: codingPath,
                        debugDescription: "Missing internal persistent-system registry"))
            }
            return registry
        }
    }
}

var persistentSystemRegistryUserInfoKey: CodingUserInfoKey {
    guard let key = CodingUserInfoKey(rawValue: "diorama.persistence.registry") else {
        preconditionFailure("The static registry coding key must be valid")
    }
    return key
}

func persistedScenarioCodingError(for error: DecodingError) -> PersistedScenarioCodingError {
    switch error {
    case let .keyNotFound(key, context):
        let path = persistedCodingPath(context.codingPath)
        if (path.isEmpty && key.stringValue == "diorama") ||
            (path == ["diorama"] && key.stringValue == "schemaVersion")
        {
            return .unversionedEnvelope
        }
        return .malformed(codingPath: path + [key.stringValue])
    case let .typeMismatch(_, context):
        if context.codingPath.isEmpty {
            return .unversionedEnvelope
        }
        return .malformed(codingPath: persistedCodingPath(context.codingPath))
    case let .valueNotFound(_, context),
         let .dataCorrupted(context):
        return .malformed(codingPath: persistedCodingPath(context.codingPath))
    @unknown default:
        return .malformed(codingPath: [])
    }
}
