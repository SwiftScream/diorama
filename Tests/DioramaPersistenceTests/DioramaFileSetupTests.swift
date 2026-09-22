import Diorama
import DioramaCore
import DioramaPersistence
import DioramaRandom
import Foundation
import Synchronization
import Testing

struct DioramaFileSetupTests {
    @Test
    func `file setup reads fresh content per run and explicit definition stays fixed`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let location = try ScenarioFileLocation(rootDirectory: directory, relativePath: "scenario.json")
        let factories = Mutex(0)
        let random = try DioramaRandomSystem.instance(for: "boundaries") {
            factories.withLock { $0 += 1 }
            return SystemRandomNumberGenerator()
        }
        // Even the directory is absent at construction; replay must read only at start.
        let setup = try Diorama(file: location.fileURL, scenarioID: "file-setup", mode: .replay, systems: random)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try persistedFixture("random-boundaries")
        try original.write(to: location.fileURL)
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([random.type]))
        let fixed = try Diorama(definition: codec.decode(original), scenarioID: "file-setup",
                                mode: .replay, systems: random)
        let first = try await setup.execute { generator in var generator = generator; return generator.next() }
        let originalText = try #require(String(data: original, encoding: .utf8))
        let changed = Data(originalText.replacingOccurrences(
            of: "          0,", with: "          17,").utf8)
        try changed.write(to: location.fileURL)
        let second = try await setup.execute { generator in var generator = generator; return generator.next() }
        let pinned = try await fixed.execute { generator in var generator = generator; return generator.next() }
        #expect(first.body == 0)
        #expect(second.body == 17)
        #expect(pinned.body == 0)
        #expect(pinned.loadResult == nil)
        #expect(try Data(contentsOf: location.fileURL) == changed)
        #expect(factories.withLock { $0 } == 0)
    }

    @Test
    func `repeated persistent instances share codecs and start without a second registry declaration`() async throws {
        let location = try ScenarioFileLocation(
            rootDirectory: FileManager.default.temporaryDirectory, relativePath: UUID().uuidString + ".json")
        let first = try DioramaRandomSystem.instance(for: "first")
        let second = try DioramaRandomSystem.instance(for: "second")
        let setup = try Diorama(
            file: location.fileURL,
            scenarioID: "record", mode: .record,
            systems: first, second)
        let result = try await setup.execute { first, second in
            var first = first
            var second = second
            _ = first.next()
            _ = second.next()
        }
        guard case .missing = result.loadResult else { Issue.record("Expected missing file"); return }
        #expect(result.finalization.usage.count == 2)
        #expect(result.finalization.report.diagnostics.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: location.fileURL.path))
    }

    @Test
    func `unknown inactive types are omitted while standalone decode remains strict`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = try ScenarioFileLocation(rootDirectory: directory, relativePath: "scenario.json")
        let registration = extraRegistration()
        let inactive = ScenarioAttachment(id: AttachmentID(
            systemTypeID: registration.id, key: AttachmentKey(rawValue: "inactive")))
        let random = try DioramaRandomSystem.instance(for: "boundaries")
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([
            random.type, registration,
        ]))
        let randomBaseline = try codec.decode(persistedFixture("random-boundaries"))
        let baseline = try ScenarioDefinition(attachments: randomBaseline.attachments + [inactive])
        let bytes = try codec.encode(baseline)
        try bytes.write(to: location.fileURL)
        let unknown = try Diorama(file: location.fileURL, scenarioID: "file-setup", mode: .replay,
                                  systems: random)
        let unknownResult = try await unknown.execute { _ in () }
        guard case let .loaded(available, skipped) = unknownResult.loadResult else {
            Issue.record("Expected available content and skipped headers"); return
        }
        #expect(available.attachments.count == 1)
        #expect(skipped.map(\.attachmentID) == [inactive.id])
        let readable = try Diorama(
            file: location.fileURL, scenarioID: "file-setup", mode: .replay, systems: random)
        let result = try await readable.execute { generator in
            var generator = generator
            _ = generator.next()
            _ = generator.next()
        }
        #expect(result.finalization.report.diagnostics.map(\.diagnostic.issue) == [
            .baseline(.loadedAttachmentNotConfigured),
        ])
        let baselineText = try #require(String(data: bytes, encoding: .utf8))
        let corrupt = Data(baselineText.replacingOccurrences(
            of: "\"payload\" : 42", with: "\"payload\" : \"invalid\"").utf8)
        #expect(corrupt != bytes)
        try corrupt.write(to: location.fileURL)
        _ = try await readable.execute { _ in () }
        #expect(throws: (any Error).self) { try codec.decode(corrupt) }
    }

    @Test
    func `conflicting descriptors missing capabilities and mismatched attachments are rejected`() throws {
        let location = try ScenarioFileLocation(
            rootDirectory: FileManager.default.temporaryDirectory, relativePath: "unused.json")
        let probe = StartupProbe()
        let system = try probe.system(key: "random")
        #expect(throws: ScenarioDefinitionError.self) {
            try ScenarioSystem(type: extraRegistration(), attachment: system.attachment) { _ in
                PreparedSystem { ActivatedSystem(dependency: true, deactivate: {}) }
            }
        }
        let firstType = extraRegistration()
        let first = try persistentExtra("first", registration: firstType)
        let second = try persistentExtra("second", registration: extraRegistration())
        #expect(throws: PersistenceRegistrationError.duplicateSystemType(firstType.id)) {
            try Diorama(file: location.fileURL, scenarioID: "file-setup", mode: .replay, systems: first, second)
        }
        let ephemeralType = ScenarioSystemType("consumer.ephemeral")
        let ephemeral = try persistentExtra("ephemeral", registration: ephemeralType)
        #expect(throws: PersistenceRegistrationError.missingPersistence(ephemeralType.id)) {
            try Diorama(file: location.fileURL, scenarioID: "file-setup", mode: .replay, systems: ephemeral)
        }
        #expect(probe.preparationCount == 0)
    }

    @Test
    func `file setup rejects nonfile and directory URLs before accessing storage`() throws {
        let random = try DioramaRandomSystem.instance(for: "random")
        let remote = try #require(URL(string: "https://example.com/scenario.json"))
        #expect(throws: ScenarioFileLocationError.invalidRoot) {
            _ = try Diorama(file: remote, scenarioID: "file-setup", mode: .replay, systems: random)
        }
        #expect(throws: ScenarioFileLocationError.invalidRoot) {
            _ = try Diorama(
                file: FileManager.default.temporaryDirectory,
                scenarioID: "file-setup", mode: .replay, systems: random)
        }
    }

    private func extraRegistration() -> ScenarioSystemType {
        let type = SystemTypeID(rawValue: "consumer.extra")
        return ScenarioSystemType(id: type, persistence: PersistentSystemRegistration(
            currentSchemaVersion: 1, payloadType: Int.self,
            encode: { _ in 42 },
            decode: { _, key in ScenarioAttachment(id: AttachmentID(systemTypeID: type, key: key)) }))
    }

    private func persistentExtra(
        _ key: String, registration: ScenarioSystemType) throws -> ScenarioSystem<Bool>
    {
        let attachment = ScenarioAttachment(id: AttachmentID(
            systemTypeID: registration.id, key: AttachmentKey(rawValue: key)))
        return try ScenarioSystem(type: registration, attachment: attachment) { _ in
            PreparedSystem { ActivatedSystem(dependency: true, deactivate: {}) }
        }
    }
}
