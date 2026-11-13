import DioramaCore
import DioramaHTTP
@testable import DioramaPersistence
import Foundation
import HTTPTypes
import Synchronization
import Testing

struct HTTPResourceRepositoryTests {
    @Test
    func `HTTP resources publish exact bytes and load into independently owned values`() throws {
        let fixture = try ResourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bytes: [UInt8] = [0, 255, 128, 13, 10]
        let original = try fixture.definition(bytes)
        let encoded = try fixture.codec.encode(original)
        #expect(throws: ScenarioResourceError.unavailable) { try fixture.codec.decode(encoded.data) }
        _ = try fixture.repository.publish(original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() ==
            ["scenario-resources", "scenario.json"])
        let loaded = try fixture.loaded()
        let resource = try fixture.resource(in: loaded)
        #expect(resource.bytes() == bytes)
        let request = try HTTPRequestMessage(
            head: HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/"),
            body: .resource(resource))
        let inline = try HTTPRequestMessage(head: request.head, body: .bytes(bytes))
        let preparation = ValuePreparation<HTTPRequestMessage>()
        #expect(try HTTPRequestMatcher().project(preparation.admitPrepared(request)) ==
            HTTPRequestMatcher().project(preparation.admitPrepared(inline)))
        let originalDocument = try fixture.codec.encode(original)
        let loadedDocument = try fixture.codec.encode(loaded)
        #expect(originalDocument.data == loadedDocument.data)
        #expect(originalDocument.resources == loadedDocument.resources)
        _ = try fixture.repository.publish(fixture.definition([9]))
        #expect(resource.bytes() == bytes)
        try FileManager.default.removeItem(at: fixture.root)
        #expect(try fixture.resource(in: original).bytes() == bytes)
        #expect(resource.bytes() == bytes)
    }

    @Test
    func `body decoding validates before reading and resolves each reference once`() throws {
        let reads = Mutex<[String]>([])
        let decoder = JSONDecoder()
        decoder.userInfo[resourceCodingKey] = ScenarioDocumentSnapshot(data: Data()) { path in
            reads.withLock { $0.append(path.value) }
            return Data([0, 255])
        }
        let conflicting = Data(#"{"kind":"resource","resource":"body.bin","text":"extra"}"#.utf8)
        #expect(throws: HTTPMessageError.invalidBody) {
            try decoder.decode(HTTPResponseBody.self, from: conflicting)
        }
        let escaping = Data(#"{"kind":"resource","resource":"../body.bin"}"#.utf8)
        #expect(throws: HTTPMessageError.invalidResource) {
            try decoder.decode(HTTPResponseBody.self, from: escaping)
        }
        #expect(reads.withLock { $0.isEmpty })
        let valid = Data(#"{"kind":"resource","resource":"body.bin"}"#.utf8)
        let body = try decoder.decode(HTTPResponseBody.self, from: valid)
        guard case let .resource(resource) = body else { Issue.record("Missing owned resource"); return }
        #expect(resource.bytes() == [0, 255])
        #expect(reads.withLock { $0 } == ["body.bin"])
    }

    @Test
    func `failed publication leaves healthy definitions usable for a later destination`() throws {
        let fixture = try ResourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try fixture.definition([1, 2, 3])
        var operations = FileStorageOperations()
        operations.commit = { _, _ in throw ScenarioResourceError.unavailable }
        let failed = JSONScenarioRepository(codec: fixture.codec,
                                            storage: FileScenarioStorage(
                                                location: fixture.location,
                                                operations: operations))
        #expect(throws: ScenarioPublicationError.self) { try failed.publish(original) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        #expect(try fixture.resource(in: original).bytes() == [1, 2, 3])
        _ = try fixture.repository.publish(original)
        #expect(try fixture.resource(in: fixture.loaded()).bytes() == [1, 2, 3])
    }

    @Test
    func `edited bytes load literally and missing resources fail as infrastructure`() throws {
        let fixture = try ResourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.repository.publish(fixture.definition([1]))
        let bodyURL = fixture.root.appendingPathComponent("scenario-resources/bodies/reply.bin")
        try Data([0, 128, 255, 2]).write(to: bodyURL)
        #expect(try fixture.resource(in: fixture.loaded()).bytes() == [0, 128, 255, 2])
        try FileManager.default.removeItem(at: bodyURL)
        guard case let .invalidDocument(error) = fixture.repository.load() else {
            Issue.record("Missing resource was accepted"); return
        }
        #expect(error as? ScenarioResourceError == .unavailable)
    }

    @Test
    func `only prepared bytes are staged and loaded without repeating transforms`() throws {
        let fixture = try ResourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reporter = try DiagnosticReporter(
            scenarioID: ScenarioID(rawValue: "resources"),
            definition: ScenarioDefinition())
        let policy = ValuePreparation<[UInt8]>(redact: { _ in Array("safe".utf8) }, normalize: { $0 + [10] })
        let prepared = try policy.prepare(
            capturing: { Array("secret".utf8) },
            purpose: .recording,
            reporter: reporter)
        let body = try HTTPResponseBody.resource(HTTPBodyResource(path: "bodies/reply.bin", bytes: prepared))
        let definition = try ResourceFixture.definition([body])
        _ = try fixture.repository.publish(definition)
        #expect(try fixture.resource(in: fixture.loaded()).bytes() == Array("safe\n".utf8))
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("scenario-resources/bodies/reply.bin")) ==
            Data("safe\n".utf8))
    }

    @Test
    func `conflicting resources never reach publication`() throws {
        let fixture = try ResourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try fixture.resource(in: fixture.definition([1]))
        let second = try fixture.resource(in: fixture.definition([2]))
        #expect(throws: ScenarioPublicationError.self) {
            try fixture.repository.publish(ResourceFixture.definition([.resource(first), .resource(second)]))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        _ = try fixture.repository.publish(ResourceFixture.definition([.resource(first), .resource(first)]))
        #expect(try fixture.resource(in: fixture.loaded()).bytes() == [1])
    }
}

private struct ResourceFixture {
    let root: URL
    let location: ScenarioFileLocation
    let codec: JSONScenarioCodec
    var repository: JSONScenarioRepository {
        JSONScenarioRepository(codec: codec, storage: FileScenarioStorage(location: location))
    }

    static let key = AttachmentKey(rawValue: "http")
    static let typeID = SystemTypeID(rawValue: "test.http-resource")
    static let attachmentID = AttachmentID(systemTypeID: typeID, key: key)
    static let trackID = TrackID(attachmentID: attachmentID, key: TrackKey(rawValue: "bodies"))

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-h07-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        location = try ScenarioFileLocation(rootDirectory: root, relativePath: "scenario.json")
        let registration = PersistentSystemRegistration(
            currentSchemaVersion: 1,
            payloadType: [HTTPResponseBody].self,
            encode: { attachment in
                try #require(try attachment.track(Self.trackID, as: HTTPResponseBody.self)).records.map(\.value)
            },
            decode: { bodies, _ in try Self.definition(bodies).attachments[0] })
        codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([
            ScenarioSystemType(Self.typeID.rawValue, persistence: registration),
        ]))
    }

    func definition(_ bytes: [UInt8]) throws -> ScenarioDefinition {
        let prepared = try ValuePreparation<[UInt8]>().admitPrepared(bytes)
        return try Self.definition([.resource(HTTPBodyResource(path: "bodies/reply.bin", bytes: prepared))])
    }

    static func definition(_ bodies: [HTTPResponseBody]) throws -> ScenarioDefinition {
        let values = try bodies.map { try ValuePreparation<HTTPResponseBody>().admitPrepared($0) }
        let attachment = try ScenarioAttachment(id: attachmentID).adding(SequentialTrack(id: trackID, values: values))
        return try ScenarioDefinition(attachments: [attachment])
    }

    func resource(in definition: ScenarioDefinition) throws -> HTTPBodyResource {
        let track = try #require(try definition.attachments[0].track(Self.trackID, as: HTTPResponseBody.self))
        guard case let .resource(resource) = try #require(track.records.first).value else {
            throw ScenarioResourceError.unavailable
        }
        return resource
    }

    func loaded() throws -> ScenarioDefinition {
        guard case let .loaded(definition, _) = repository.load() else { throw ScenarioResourceError.unavailable }
        return definition
    }
}
