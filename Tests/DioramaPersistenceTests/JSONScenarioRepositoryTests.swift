import DioramaCore
@testable import DioramaPersistence
import DioramaRandom
import Foundation
import Synchronization
import Testing

struct JSONScenarioRepositoryTests {
    @Test
    func `missing zero byte and empty valid scenarios remain distinct`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let repository = try repository(storage: fixture.storage)
        guard case .missing = repository.load() else {
            Issue.record("Absent content did not report missing"); return
        }
        try Data().write(to: fixture.location.fileURL)
        guard case .invalidDocument = repository.load() else {
            Issue.record("Zero-byte document was accepted"); return
        }
        _ = try repository.publish(ScenarioDefinition())
        guard case let .loaded(empty, _) = repository.load() else {
            Issue.record("Valid empty document did not load"); return
        }
        #expect(empty.attachments.isEmpty)
        #expect(try fixture.entries() == ["scenario.json"])
    }

    @Test
    func `independent random fixture loads and publishes byte identically`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let bytes = try persistedFixture("random-boundaries")
        try bytes.write(to: fixture.location.fileURL)
        let repository = try repository(storage: fixture.storage)
        guard case let .loaded(scenario, _) = repository.load() else {
            Issue.record("Fixture did not load"); return
        }
        let attachment = try #require(scenario.attachments.first)
        let track = try #require(try attachment.track(
            DioramaRandomSystem.trackID(for: attachment.id.key), as: UInt64.self))
        #expect(track.records.map(\.value) == [0, .max])
        _ = try repository.publish(scenario)
        #expect(try fixture.storage.load() == bytes)
    }

    @Test(arguments: ["unversioned-poc", "unsupported-envelope-version"])
    func `incompatible envelopes preserve original bytes`(name: String) throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let bytes = try persistedFixture(name)
        try bytes.write(to: fixture.location.fileURL)
        guard case let .incompatibleEnvelope(error) = try repository(storage: fixture.storage).load() else {
            Issue.record("Expected incompatible envelope"); return
        }
        #expect(error == (name == "unversioned-poc" ? .unversionedEnvelope :
                .unsupportedEnvelopeVersion(declared: 2, supported: [1])))
        #expect(try fixture.storage.load() == bytes)
        #expect(try fixture.entries() == ["scenario.json"])
    }

    @Test(arguments: [
        "unknown-envelope-field", "malformed-random-values", "unknown-random-field",
    ])
    func `invalid structure and system validation remain invalid documents`(name: String) throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let bytes = try persistedFixture(name)
        try bytes.write(to: fixture.location.fileURL)
        guard case .invalidDocument = try repository(storage: fixture.storage).load() else {
            Issue.record("Expected invalid document"); return
        }
        #expect(try fixture.storage.load() == bytes)
    }

    @Test
    func `missing registration and unsupported payload version retain exact dispatch errors`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        try persistedFixture("random-boundaries").write(to: fixture.location.fileURL)
        let emptyRegistry = try JSONScenarioRepository(
            codec: JSONScenarioCodec(registry: PersistentSystemRegistry()), storage: fixture.storage)
        guard case let .incompatibleSystem(unknown) = emptyRegistry.load() else {
            Issue.record("Expected missing registration"); return
        }
        #expect(unknown == .unknownSystemType(DioramaRandomSystem.systemTypeID))
        let unsupportedVersions: [(String, UInt32)] = [
            ("unsupported-random-version", 2),
            ("zero-random-version", 0),
        ]
        for (fixtureName, declared) in unsupportedVersions {
            try persistedFixture(fixtureName).write(to: fixture.location.fileURL)
            guard case let .incompatibleSystem(version) = try repository(storage: fixture.storage).load() else {
                Issue.record("Expected unsupported payload version"); return
            }
            #expect(version == .unsupportedSchemaVersion(
                systemTypeID: DioramaRandomSystem.systemTypeID,
                declared: declared,
                supported: [DioramaRandomPersistence.schemaVersion]))
        }
    }

    @Test
    func `unreadable storage preserves the backend failure and reads once`() throws {
        let calls = Mutex(0)
        let storage = StubDocumentStorage(read: {
            calls.withLock { $0 += 1 }
            throw FileStorageError(operation: .read, cause: .posix(13))
        })
        guard case let .unreadable(error) = try repository(storage: storage).load() else {
            Issue.record("Expected unreadable storage"); return
        }
        #expect(error as? FileStorageError == FileStorageError(operation: .read, cause: .posix(13)))
        #expect(calls.withLock { $0 } == 1)
    }

    @Test
    func `custom storage shares the codec and each load takes one immutable snapshot`() throws {
        let bytes = try persistedFixture("random-boundaries")
        let calls = Mutex(0)
        let written = Mutex<Data?>(nil)
        let storage = StubDocumentStorage(read: {
            calls.withLock { $0 += 1 }
            return bytes
        }, write: { data in
            written.withLock { $0 = data }
            return DocumentPublication()
        })
        let repository = try repository(storage: storage)
        guard case let .loaded(scenario, _) = repository.load() else {
            Issue.record("Expected loaded custom storage"); return
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(written.withLock { $0 } == nil)
        _ = try repository.publish(scenario)
        #expect(written.withLock { $0 } == bytes)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test
    func `encoding failure touches no storage and preserves the prior file`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let bytes = try persistedFixture("random-boundaries")
        try bytes.write(to: fixture.location.fileURL)
        let invalid = ScenarioAttachment(id: DioramaRandomSystem.attachmentID(for: AttachmentKey(rawValue: "bad")))
        let candidate = try ScenarioDefinition(attachments: [invalid])
        var operations = FileStorageOperations()
        operations.createDirectory = { _ in Issue.record("Encoding failure reached storage"); throw storageFault() }
        let repository = try repository(storage: FileScenarioStorage(
            location: fixture.location, operations: operations))
        do {
            _ = try repository.publish(candidate)
            Issue.record("Invalid candidate published")
        } catch {
            guard case let .encoding(cause) = error else { Issue.record("Wrong failure stage"); return }
            #expect(cause as? PersistentSystemEncodingError == .invalidTrackLayout(invalid.id))
        }
        #expect(try fixture.storage.load() == bytes)
        #expect(try fixture.entries() == ["scenario.json"])
    }

    @Test
    func `repository preserves storage stage and committed cleanup receipt`() throws {
        let failure = FileStorageError(operation: .commit, cause: .posix(5), cleanupFailure: .posix(13))
        let failing = try repository(storage: StubDocumentStorage(write: { _ in throw failure }))
        let candidate = try ScenarioDefinition()
        do {
            _ = try failing.publish(candidate)
            Issue.record("Expected storage failure")
        } catch {
            guard case let .storage(cause) = error else { Issue.record("Wrong failure stage"); return }
            #expect(cause as? FileStorageError == failure)
        }
        let cleanup = FileStorageError(operation: .cleanup, cause: .posix(13))
        let committed = try repository(storage: StubDocumentStorage(write: { _ in
            DocumentPublication(cleanupFailure: cleanup)
        }))
        #expect(try committed.publish(candidate).cleanupFailure as? FileStorageError == cleanup)
    }

    private func repository(storage: any ScenarioDocumentStorage) throws -> JSONScenarioRepository {
        try JSONScenarioRepository(codec: JSONScenarioCodec(registry: PersistentSystemRegistry([
            DioramaRandomSystem.type,
        ])), storage: storage)
    }
}

private struct StubDocumentStorage: ScenarioDocumentStorage {
    var read: @Sendable () throws -> Data? = { nil }
    var write: @Sendable (Data) throws -> DocumentPublication = { _ in DocumentPublication() }

    func load() throws -> Data? {
        try read()
    }

    func publish(_ document: Data) throws -> DocumentPublication {
        try write(document)
    }
}
