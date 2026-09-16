import DioramaCore
import DioramaPersistence
import Foundation
import Testing

struct PersistentSystemRegistryTests {
    struct NumberPayload: Codable, Equatable, Sendable {
        let values: [Int]
    }

    struct LegacyNumberPayload: Codable, Equatable, Sendable {
        let value: Int
    }

    struct LabelPayload: Codable, Equatable, Sendable {
        let values: [String]
    }

    struct NonCodableValue: Equatable, Sendable {
        let value: Int
    }

    enum FixtureError: Error, Equatable, Sendable {
        case missingTrack
    }

    static let numberType = SystemTypeID(rawValue: "test.numbers")
    static let labelType = SystemTypeID(rawValue: "test.labels")
    static let nonPersistableType = SystemTypeID(rawValue: "test.ephemeral")

    @Test
    func `schema versions span non-negative UInt32 values`() throws {
        let registration = try Self.numberRegistration(current: .max).addingReader(
            for: 0,
            payloadType: LegacyNumberPayload.self)
        { payload, key in
            try Self.numberAttachment(key: key.rawValue, values: [payload.value])
        }

        #expect(registration.currentSchemaVersion == UInt32.max)
        #expect(registration.supportedSchemaVersions == [0, UInt32.max])
    }

    @Test
    func `dispatches heterogeneous and repeated system attachments`() throws {
        let current: UInt32 = 2
        let registry = try PersistentSystemRegistry([
            Self.numberRegistration(current: current),
            Self.labelRegistration(current: 4),
        ])
        let first = try Self.numberAttachment(key: "first", values: [1, 2])
        let second = try Self.numberAttachment(key: "second", values: [3])
        let labels = try Self.labelAttachment(key: "labels", values: ["a", "b"])

        let firstRoundTrip = try roundTrip(first, registry: registry)
        let secondRoundTrip = try roundTrip(second, registry: registry)
        let labelRoundTrip = try roundTrip(labels, registry: registry)

        #expect(firstRoundTrip.descriptor.attachmentID == first.id)
        #expect(firstRoundTrip.descriptor.schemaVersion == current)
        #expect(try Self.values(in: firstRoundTrip.attachment, as: Int.self) == [1, 2])
        #expect(secondRoundTrip.descriptor.attachmentID == second.id)
        #expect(try Self.values(in: secondRoundTrip.attachment, as: Int.self) == [3])
        #expect(labelRoundTrip.descriptor.attachmentID == labels.id)
        #expect(try Self.values(in: labelRoundTrip.attachment, as: String.self) == ["a", "b"])
    }

    @Test
    func `routes an explicitly supported historical reader`() throws {
        let current: UInt32 = 2
        let legacy: UInt32 = 1
        let registration = try Self.numberRegistration(current: current).addingReader(
            for: legacy,
            payloadType: LegacyNumberPayload.self)
        { payload, key in
            try Self.numberAttachment(key: key.rawValue, values: [payload.value])
        }
        let registry = try PersistentSystemRegistry([registration])
        let descriptor = PersistedSystemDescriptor(
            attachmentKey: AttachmentKey(rawValue: "legacy"),
            systemTypeID: Self.numberType,
            schemaVersion: legacy)

        let attachment = try decodePropertyList(
            LegacyNumberPayload(value: 41),
            descriptor: descriptor,
            registry: registry)

        #expect(registration.supportedSchemaVersions == [legacy, current])
        #expect(try Self.values(in: attachment, as: Int.self) == [41])
    }

    @Test
    func `rejects duplicate registrations and readers`() throws {
        let current: UInt32 = 2
        let registration = Self.numberRegistration(current: current)

        #expect(throws: PersistenceRegistrationError.duplicateSystemType(Self.numberType)) {
            _ = try PersistentSystemRegistry([registration, registration])
        }
        #expect(throws: PersistenceRegistrationError.duplicateReader(
            systemTypeID: Self.numberType,
            version: current))
        {
            _ = try registration.addingReader(for: current, payloadType: NumberPayload.self) { payload, key in
                try Self.numberAttachment(key: key.rawValue, values: payload.values)
            }
        }
    }

    @Test
    func `distinguishes unknown types from unsupported versions`() throws {
        let current: UInt32 = 2
        let unsupported: UInt32 = 7
        let registry = try PersistentSystemRegistry([Self.numberRegistration(current: current)])
        let unknown = SystemTypeID(rawValue: "test.unknown")
        let unknownDescriptor = PersistedSystemDescriptor(
            attachmentKey: AttachmentKey(rawValue: "unknown"),
            systemTypeID: unknown,
            schemaVersion: current)
        let unsupportedDescriptor = PersistedSystemDescriptor(
            attachmentKey: AttachmentKey(rawValue: "numbers"),
            systemTypeID: Self.numberType,
            schemaVersion: unsupported)

        #expect(throws: PersistenceDispatchError.unknownSystemType(unknown)) {
            _ = try decodePropertyList(
                NumberPayload(values: []),
                descriptor: unknownDescriptor,
                registry: registry)
        }
        #expect(throws: PersistenceDispatchError.unsupportedSchemaVersion(
            systemTypeID: Self.numberType,
            declared: unsupported,
            supported: [current]))
        {
            _ = try decodePropertyList(
                NumberPayload(values: []),
                descriptor: unsupportedDescriptor,
                registry: registry)
        }
    }

    @Test
    func `rejects a reader returning an incompatible attachment identity`() throws {
        let current: UInt32 = 1
        let registration = PersistentSystemRegistration(
            systemTypeID: Self.numberType,
            currentSchemaVersion: current,
            payloadType: NumberPayload.self,
            encode: { _ in NumberPayload(values: []) },
            decode: { payload, _ in
                try Self.numberAttachment(key: "wrong", values: payload.values)
            })
        let registry = try PersistentSystemRegistry([registration])
        let descriptor = PersistedSystemDescriptor(
            attachmentKey: AttachmentKey(rawValue: "expected"),
            systemTypeID: Self.numberType,
            schemaVersion: current)

        #expect(throws: PersistenceDispatchError.incompatibleRegistration(
            expected: descriptor.attachmentID,
            decoded: Self.numberID(key: "wrong")))
        {
            _ = try decodePropertyList(
                NumberPayload(values: [1]),
                descriptor: descriptor,
                registry: registry)
        }
    }

    @Test
    func `refuses an unknown system type without changing in-memory use`() throws {
        let attachment = try Self.nonCodableAttachment(key: "ephemeral", values: [NonCodableValue(value: 9)])
        let definition = try ScenarioDefinition(
            id: ScenarioID(rawValue: "ephemeral"),
            defaultMode: .replay,
            attachments: [attachment],
            ignoredAttachments: [attachment.id.key])
        let registry = try PersistentSystemRegistry()

        #expect(try Self.values(in: attachment, as: NonCodableValue.self) == [NonCodableValue(value: 9)])
        #expect(throws: PersistenceDispatchError.unknownSystemType(attachment.id.systemTypeID)) {
            try registry.validatePersistability(of: definition)
        }
        #expect(throws: PersistenceDispatchError.unknownSystemType(attachment.id.systemTypeID)) {
            _ = try registry.encode(attachment, to: UnusedEncoder())
        }
    }

    private func roundTrip(
        _ attachment: ScenarioAttachment,
        registry: PersistentSystemRegistry)
        throws -> (descriptor: PersistedSystemDescriptor, attachment: ScenarioAttachment)
    {
        let encoded = try encodePropertyList(attachment, registry: registry)
        let decoded = try decodePropertyList(
            encoded.data,
            descriptor: encoded.descriptor,
            registry: registry)
        return (encoded.descriptor, decoded)
    }

    private func encodePropertyList(
        _ attachment: ScenarioAttachment,
        registry: PersistentSystemRegistry)
        throws -> (data: Data, descriptor: PersistedSystemDescriptor)
    {
        let writer = PropertyListPayloadWriter(
            attachment: attachment,
            registry: registry)
        let data = try PropertyListEncoder().encode(writer)
        guard let descriptor = writer.descriptor else {
            throw PropertyListPayloadCodingError.missingDescriptor
        }
        return (data, descriptor)
    }

    private func decodePropertyList(
        _ data: Data,
        descriptor: PersistedSystemDescriptor,
        registry: PersistentSystemRegistry) throws -> ScenarioAttachment
    {
        let decoder = PropertyListDecoder()
        decoder.userInfo[propertyListPayloadContextKey] = PropertyListPayloadContext(
            descriptor: descriptor,
            registry: registry)
        return try decoder.decode(PropertyListPayloadReader.self, from: data).attachment
    }

    private func decodePropertyList(
        _ value: some Encodable & Sendable,
        descriptor: PersistedSystemDescriptor,
        registry: PersistentSystemRegistry) throws -> ScenarioAttachment
    {
        let data = try PropertyListEncoder().encode(value)
        return try decodePropertyList(data, descriptor: descriptor, registry: registry)
    }
}

private final class PropertyListPayloadWriter: Encodable {
    let attachment: ScenarioAttachment
    let registry: PersistentSystemRegistry
    private(set) var descriptor: PersistedSystemDescriptor?

    init(
        attachment: ScenarioAttachment,
        registry: PersistentSystemRegistry)
    {
        self.attachment = attachment
        self.registry = registry
    }

    func encode(to encoder: any Encoder) throws {
        descriptor = try registry.encode(attachment, to: encoder)
    }
}

private struct PropertyListPayloadReader: Decodable {
    let attachment: ScenarioAttachment

    init(from decoder: any Decoder) throws {
        guard let context = decoder.userInfo[propertyListPayloadContextKey]
            as? PropertyListPayloadContext
        else {
            throw PropertyListPayloadCodingError.missingContext
        }
        attachment = try context.registry.decode(context.descriptor, from: decoder)
    }
}

private struct PropertyListPayloadContext {
    let descriptor: PersistedSystemDescriptor
    let registry: PersistentSystemRegistry
}

private enum PropertyListPayloadCodingError: Error {
    case missingContext
    case missingDescriptor
}

private struct UnusedEncoder: Encoder {
    let codingPath: [any CodingKey] = []
    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(
        keyedBy _: Key.Type) -> KeyedEncodingContainer<Key>
    {
        preconditionFailure("The unregistered attachment must fail before encoding")
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        preconditionFailure("The unregistered attachment must fail before encoding")
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        preconditionFailure("The unregistered attachment must fail before encoding")
    }
}

private var propertyListPayloadContextKey: CodingUserInfoKey {
    guard let key = CodingUserInfoKey(rawValue: "org.swift.diorama.tests.payload-context") else {
        preconditionFailure("The test payload context key must be valid")
    }
    return key
}
