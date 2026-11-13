@testable import DioramaPersistence
import Dispatch
import Foundation
import Synchronization
import Testing

struct FileScenarioStorageTests {
    @Test
    func `staging directory creation exclusively acquires a new name`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let directory = fixture.root.appendingPathComponent("occupied")
        let operations = FileStorageOperations()
        try operations.createDirectory(directory)
        let sentinel = directory.appendingPathComponent("sentinel")
        try Data([9]).write(to: sentinel)
        #expect(throws: (any Error).self) { try operations.createDirectory(directory) }
        #expect(try Data(contentsOf: sentinel) == Data([9]))
    }

    @Test
    func `missing and zero bytes differ and loading never creates directories`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let missingParent = try ScenarioFileLocation(
            rootDirectory: fixture.root, relativePath: "absent/scenario.json")
        #expect(try FileScenarioStorage(location: missingParent).load() == nil)
        #expect(try fixture.entries().isEmpty)
        #expect(try fixture.storage.load() == nil)
        try Data().write(to: fixture.location.fileURL)
        #expect(try fixture.storage.load()?.data == Data())
    }

    @Test
    func `publication creates then replaces exact bytes and cleans staging`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let old = try persistedFixture("random-boundaries")
        let new = try persistedFixture("random-empty")
        #expect(try fixture.storage.publish(ScenarioDocument(data: old)).cleanupFailure == nil)
        #expect(try fixture.storage.load()?.data == old)
        #expect(try fixture.storage.publish(ScenarioDocument(data: new)).cleanupFailure == nil)
        #expect(try fixture.storage.load()?.data == new)
        #expect(try fixture.entries() == ["scenario.json"])
    }

    @Test
    func `read only content needs no write permission or staging operations`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let original = try persistedFixture("random-boundaries")
        try original.write(to: fixture.location.fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: fixture.location.fileURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.root.path)
        var operations = FileStorageOperations()
        operations.createDirectory = { _ in Issue.record("Load tried to create staging"); throw storageFault() }
        operations.write = { _, _ in Issue.record("Load tried to write"); throw storageFault() }
        operations.commit = { _, _ in Issue.record("Load tried to commit"); throw storageFault() }
        operations.remove = { _ in Issue.record("Load tried to clean staging"); throw storageFault() }
        let storage = FileScenarioStorage(location: fixture.location, operations: operations)
        #expect(try storage.load()?.data == original)
        #expect(try fixture.entries() == ["scenario.json"])
    }

    @Test
    func `unreadable remains distinct from missing with bounded error evidence`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        var operations = FileStorageOperations()
        operations.read = { _ in throw storageFault(13) }
        let storage = FileScenarioStorage(location: fixture.location, operations: operations)
        #expect(throws: FileStorageError(operation: .read, cause: .posix(13))) {
            _ = try storage.load()
        }
        #expect(!String(describing: FileStorageFailureCode(storageFault())).contains("secret"))
        #expect(FileStorageFailureCode(NSError(domain: "private-domain", code: 1)) == .other)
        #expect(FileStorageFailureCode(NSError(domain: NSCocoaErrorDomain, code: 257)) == .cocoa(257))
    }

    @Test
    func `real directory and invalid parent reads are unreadable`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.location.fileURL, withIntermediateDirectories: false)
        #expect(throws: FileStorageError.self) { _ = try fixture.storage.load() }
        let parentFile = fixture.root.appendingPathComponent("parent-file")
        try Data([1]).write(to: parentFile)
        let nested = try ScenarioFileLocation(rootDirectory: fixture.root, relativePath: "parent-file/child")
        #expect(throws: FileStorageError.self) { _ = try FileScenarioStorage(location: nested).load() }
    }

    @Test
    func `failed staging creation leaves destination and foreign staging alone`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let old = Data([1, 2])
        try old.write(to: fixture.location.fileURL)
        let foreign = fixture.root.appendingPathComponent(".diorama-stage-another-writer")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        var operations = FileStorageOperations()
        operations.createDirectory = { _ in throw storageFault(13) }
        operations.remove = { _ in Issue.record("Removed unowned staging") }
        let storage = FileScenarioStorage(location: fixture.location, operations: operations)
        #expect(throws: FileStorageError(operation: .stage, cause: .posix(13))) {
            _ = try storage.publish(ScenarioDocument(data: Data([3])))
        }
        #expect(try storage.load()?.data == old)
        #expect(try fixture.entries() == [".diorama-stage-another-writer", "scenario.json"])
    }

    @Test(arguments: [false, true])
    func `partial stage and commit failure preserve prior file and remove abandoned bytes`(
        failCommit: Bool) throws
    {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let old = Data([1, 2])
        try old.write(to: fixture.location.fileURL)
        var operations = FileStorageOperations()
        if failCommit {
            operations.commit = { _, _ in throw storageFault() }
        } else {
            operations.write = { bytes, url in
                try bytes.prefix(1).write(to: url)
                throw storageFault()
            }
        }
        let storage = FileScenarioStorage(location: fixture.location, operations: operations)
        #expect(throws: FileStorageError(operation: failCommit ? .commit : .stage, cause: .posix(5))) {
            _ = try storage.publish(ScenarioDocument(data: Data([3, 4, 5])))
        }
        #expect(try storage.load()?.data == old)
        #expect(try fixture.entries() == ["scenario.json"])
    }

    @Test
    func `real commit failure preserves existing directory and cleans staging`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.location.fileURL, withIntermediateDirectories: false)
        let sentinel = fixture.location.fileURL.appendingPathComponent("sentinel")
        try Data([9]).write(to: sentinel)
        do {
            _ = try fixture.storage.publish(ScenarioDocument(data: Data([3])))
            Issue.record("Commit unexpectedly succeeded")
        } catch let error as FileStorageError {
            #expect(error.operation == .commit)
            #expect(error.cleanupFailure == nil)
        }
        #expect(try Data(contentsOf: sentinel) == Data([9]))
        #expect(try fixture.entries() == ["scenario.json"])
    }

    @Test
    func `missing parent is a staging failure and is never created`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let location = try ScenarioFileLocation(rootDirectory: fixture.root, relativePath: "missing/file.json")
        do {
            _ = try FileScenarioStorage(location: location).publish(ScenarioDocument(data: Data([1])))
            Issue.record("Stage unexpectedly succeeded")
        } catch let error as FileStorageError {
            #expect(error.operation == .stage)
        }
        #expect(try fixture.entries().isEmpty)
    }

    @Test(arguments: [false, true])
    func `cleanup failure retains commit disposition and any earlier failure`(failCommit: Bool) throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        try Data([1]).write(to: fixture.location.fileURL)
        var operations = FileStorageOperations()
        operations.remove = { _ in throw storageFault(13) }
        if failCommit {
            operations.commit = { _, _ in throw storageFault() }
        }
        let storage = FileScenarioStorage(location: fixture.location, operations: operations)
        if failCommit {
            #expect(throws: FileStorageError(operation: .commit, cause: .posix(5), cleanupFailure: .posix(13))) {
                _ = try storage.publish(ScenarioDocument(data: Data([2])))
            }
            #expect(try storage.load()?.data == Data([1]))
        } else {
            let receipt = try storage.publish(ScenarioDocument(data: Data([2])))
            #expect(receipt.cleanupFailure as? FileStorageError ==
                FileStorageError(operation: .cleanup, cause: .posix(13)))
            #expect(try storage.load()?.data == Data([2]))
        }
        #expect(try fixture.entries().filter { $0.hasPrefix(".diorama-stage-") }.count == 1)
    }

    @Test
    func `read only loads can run concurrently without publication`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let document = Data(repeating: 0x61, count: 262_144)
        _ = try fixture.storage.publish(ScenarioDocument(data: document))
        let failures = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            do {
                for _ in 0..<40 where try fixture.storage.load()?.data != document {
                    failures.withLock { $0 += 1 }
                }
            } catch { failures.withLock { $0 += 1 } }
        }
        #expect(failures.withLock { $0 } == 0)
        #expect(try fixture.entries() == ["scenario.json"])
    }
}
