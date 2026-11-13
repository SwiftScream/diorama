import DioramaCore
import DioramaPersistence
import Foundation
import Testing

struct ScenarioResourceRepositoryTests {
    @Test
    func `registered codec collects shared bytes and resolves them only during repository load`() throws {
        let fixture = try ResourceRepositoryFixture()
        defer { try? fixture.storage.remove() }
        let bytes: [UInt8] = [0, 255, 128, 13, 10]
        let definition = try ResourceRepositoryFixture.definition([bytes, bytes])
        let document = try fixture.codec.encode(definition)
        #expect(try document.resources == [ScenarioResourcePath("payload.bin"): Data(bytes)])

        _ = try fixture.repository.publish(definition)
        let snapshot = try #require(try fixture.storage.storage.load())
        #expect(snapshot.data == document.data)
        #expect(try snapshot.resource(at: ScenarioResourcePath("payload.bin")) == Data(bytes))
        let loaded = try fixture.loaded()
        #expect(try ResourceRepositoryFixture.contents(loaded) == [bytes, bytes])

        let resources = fixture.storage.root.appendingPathComponent("scenario-resources")
        #expect(try FileManager.default.contentsOfDirectory(atPath: resources.path) == ["payload.bin"])
        _ = try fixture.repository.publish(ResourceRepositoryFixture.definition([[9]]))
        #expect(try ResourceRepositoryFixture.contents(loaded) == [bytes, bytes])
        try fixture.storage.remove()
        #expect(try ResourceRepositoryFixture.contents(loaded) == [bytes, bytes])
    }

    @Test
    func `conflicting codec resources fail encoding before storage is touched`() throws {
        let fixture = try ResourceRepositoryFixture()
        defer { try? fixture.storage.remove() }
        let definition = try ResourceRepositoryFixture.definition([[1], [2]])
        #expect(throws: ScenarioResourceError.conflictingResource) { try fixture.codec.encode(definition) }
        do {
            _ = try fixture.repository.publish(definition)
            Issue.record("Conflicting resources published")
        } catch {
            guard case let .encoding(cause) = error else { Issue.record("Wrong failure stage"); return }
            #expect(cause as? ScenarioResourceError == .conflictingResource)
        }
        #expect(try fixture.storage.entries().isEmpty)
    }

    @Test
    func `unresolved codec resources fail encoding before storage is touched`() throws {
        let fixture = try ResourceRepositoryFixture()
        defer { try? fixture.storage.remove() }
        let definition = try ResourceRepositoryFixture.definition([nil])
        #expect(throws: ScenarioResourceError.unavailable) { try fixture.codec.encode(definition) }
        do {
            _ = try fixture.repository.publish(definition)
            Issue.record("Unresolved resource published")
        } catch {
            guard case let .encoding(cause) = error else { Issue.record("Wrong failure stage"); return }
            #expect(cause as? ScenarioResourceError == .unavailable)
        }
        #expect(try fixture.storage.entries().isEmpty)
    }

    @Test
    func `resource resolution failure rejects the document instead of dropping its payload`() throws {
        let fixture = try ResourceRepositoryFixture()
        defer { try? fixture.storage.remove() }
        _ = try fixture.repository.publish(ResourceRepositoryFixture.definition([[7]]))
        let resource = fixture.storage.root.appendingPathComponent("scenario-resources/payload.bin")
        try FileManager.default.removeItem(at: resource)
        guard case let .invalidDocument(error) = fixture.repository.load() else {
            Issue.record("Missing resource was accepted"); return
        }
        #expect(error as? ScenarioResourceError == .unavailable)
    }
}

private struct ResourceRepositoryFixture {
    let storage: FileStorageFixture
    let codec: JSONScenarioCodec
    var repository: JSONScenarioRepository {
        JSONScenarioRepository(codec: codec, storage: storage.storage)
    }

    static let typeID = SystemTypeID(rawValue: "test.resource")
    static let attachmentID = AttachmentID(systemTypeID: typeID, key: AttachmentKey(rawValue: "resource"))
    static let trackID = TrackID(attachmentID: attachmentID, key: TrackKey(rawValue: "values"))

    init() throws {
        storage = try FileStorageFixture()
        let registration = PersistentSystemRegistration(
            currentSchemaVersion: 1,
            payloadType: [ResourcePayload].self,
            encode: { attachment in
                try #require(try attachment.track(Self.trackID, as: ResourcePayload.self)).records.map(\.value)
            },
            decode: { values, _ in try Self.definition(values.map(\.bytes)).attachments[0] })
        codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([
            ScenarioSystemType(Self.typeID.rawValue, persistence: registration),
        ]))
    }

    static func definition(_ contents: [[UInt8]?]) throws -> ScenarioDefinition {
        let values = try contents.map {
            try ValuePreparation<ResourcePayload>().admitPrepared(ResourcePayload(bytes: $0))
        }
        let attachment = try ScenarioAttachment(id: attachmentID).adding(SequentialTrack(id: trackID, values: values))
        return try ScenarioDefinition(attachments: [attachment])
    }

    static func contents(_ definition: ScenarioDefinition) throws -> [[UInt8]?] {
        let attachment = try #require(definition.attachments.first)
        return try #require(try attachment.track(trackID, as: ResourcePayload.self)).records.map(\.value.bytes)
    }

    func loaded() throws -> ScenarioDefinition {
        guard case let .loaded(definition, _) = repository.load() else { throw ScenarioResourceError.unavailable }
        return definition
    }
}

private struct ResourcePayload: Codable, Sendable {
    let bytes: [UInt8]?

    init(bytes: [UInt8]?) {
        self.bytes = bytes
    }

    init(from decoder: any Decoder) throws {
        let path = try ScenarioResourcePath(String(from: decoder))
        bytes = try ScenarioResourceCoding.decode(at: path, from: decoder).map { Array($0) }
    }

    func encode(to encoder: any Encoder) throws {
        let path = try ScenarioResourcePath("payload.bin")
        if let bytes {
            try ScenarioResourceCoding.encode(ValuePreparation<[UInt8]>().admitPrepared(bytes), at: path, to: encoder)
        } else {
            try ScenarioResourceCoding.requireBytes(to: encoder)
        }
        try path.value.encode(to: encoder)
    }
}
