@testable import DioramaPersistence
import Foundation
import Testing

struct FileResourceStorageTests {
    @Test
    func `publication uses stable regular files and replaces obsolete resources`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let path = try ScenarioResourcePath("bodies/reply.bin")
        let root = fixture.root.appendingPathComponent("scenario-resources")
        _ = try fixture.storage.publish(ScenarioDocument(data: Data([1]), resources: [path: Data([11])]))
        let old = try #require(try fixture.storage.load())
        let owned = try old.resource(at: path)
        #expect(try fixture.entries() == ["scenario-resources", "scenario.json"])
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.location.fileURL.path)[.type]
            as? FileAttributeType == .typeRegular)
        #expect(try FileManager.default.attributesOfItem(atPath: root.path)[.type]
            as? FileAttributeType == .typeDirectory)

        _ = try fixture.storage.publish(ScenarioDocument(data: Data([2]), resources: [path: Data([22])]))
        let new = try #require(try fixture.storage.load())
        #expect(new.data == Data([2]))
        #expect(try new.resource(at: path) == Data([22]))
        #expect(owned == Data([11]))
        #expect(try fixture.entries() == ["scenario-resources", "scenario.json"])
        let replacement = try ScenarioResourcePath("new.bin")
        _ = try fixture.storage.publish(ScenarioDocument(data: Data([3]), resources: [replacement: Data([33])]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["new.bin"])
        _ = try fixture.storage.publish(ScenarioDocument(data: Data([4])))
        #expect(try fixture.storage.load()?.data == Data([4]))
        #expect(try fixture.entries() == ["scenario.json"])
        #expect(owned == Data([11]))
    }

    @Test(arguments: ["directory", "write", "backup", "install", "document"])
    func `failed publication restores prior JSON and resources and removes staging`(_ stage: String) throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let path = try ScenarioResourcePath("a/b.bin")
        _ = try fixture.storage.publish(ScenarioDocument(data: Data([1]), resources: [path: Data([11])]))
        let entries = try fixture.entries()
        var operations = FileStorageOperations()
        let move = operations.move
        switch stage {
        case "directory": operations.createDirectory = { _ in throw storageFault() }
        case "write": operations.write = { _, _ in throw storageFault() }
        case "backup", "install":
            operations.move = { source, destination in
                if (stage == "backup" && destination.lastPathComponent == "previous-resources") ||
                    (stage == "install" && source.lastPathComponent == "resources")
                {
                    throw storageFault()
                }
                try move(source, destination)
            }
        default: operations.commit = { _, _ in throw storageFault() }
        }
        let failed = FileScenarioStorage(location: fixture.location, operations: operations)
        #expect(throws: FileStorageError.self) {
            try failed.publish(ScenarioDocument(data: Data([2]), resources: [path: Data([22])]))
        }
        #expect(try fixture.entries() == entries)
        let restored = try #require(try fixture.storage.load())
        #expect(restored.data == Data([1]))
        #expect(try restored.resource(at: path) == Data([11]))
    }

    @Test
    func `resource cleanup errors retain the primary failure`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        var operations = FileStorageOperations()
        operations.commit = { _, _ in throw storageFault(5) }
        operations.remove = { _ in throw storageFault(13) }
        let storage = FileScenarioStorage(location: fixture.location, operations: operations)
        #expect(throws: FileStorageError(operation: .commit, cause: .posix(5), cleanupFailure: .posix(13))) {
            try storage.publish(ScenarioDocument(data: Data(), resources: [ScenarioResourcePath("a"): Data()]))
        }
        #expect(try fixture.storage.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("scenario-resources").path))
    }

    @Test
    func `resource cleanup failure after commit retains the new publication`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let path = try ScenarioResourcePath("a")
        _ = try fixture.storage.publish(ScenarioDocument(data: Data([1]), resources: [path: Data([11])]))
        var operations = FileStorageOperations()
        operations.remove = { _ in throw storageFault(13) }
        let receipt = try FileScenarioStorage(location: fixture.location, operations: operations)
            .publish(ScenarioDocument(data: Data([2]), resources: [path: Data([22])]))
        #expect(receipt.cleanupFailure as? FileStorageError == FileStorageError(operation: .cleanup, cause: .posix(13)))
        let current = try #require(try fixture.storage.load())
        #expect(current.data == Data([2]))
        #expect(try current.resource(at: path) == Data([22]))
    }

    @Test(arguments: [false, true])
    func `rollback failure retains backup bytes and reports both failures`(failWithdrawal: Bool) throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let path = try ScenarioResourcePath("a")
        _ = try fixture.storage.publish(ScenarioDocument(data: Data([1]), resources: [path: Data([11])]))
        var operations = FileStorageOperations()
        let move = operations.move
        operations.commit = { _, _ in throw storageFault(5) }
        operations.move = { source, destination in
            if (failWithdrawal && source.lastPathComponent == "scenario-resources" &&
                destination.lastPathComponent == "resources") ||
                (!failWithdrawal && source.lastPathComponent == "previous-resources")
            {
                throw storageFault(13)
            }
            try move(source, destination)
        }
        operations.remove = { _ in Issue.record("Rollback failure must retain recovery data") }
        #expect(throws: FileStorageError(operation: .commit, cause: .posix(5), rollbackFailure: .posix(13))) {
            try FileScenarioStorage(location: fixture.location, operations: operations)
                .publish(ScenarioDocument(data: Data([2]), resources: [path: Data([22])]))
        }
        #expect(try Data(contentsOf: fixture.location.fileURL) == Data([1]))
        let staging = try #require(try fixture.entries().first { $0.hasPrefix(".diorama-stage-") })
        let backup = fixture.root.appendingPathComponent(staging).appendingPathComponent("previous-resources/a")
        #expect(try Data(contentsOf: backup) == Data([11]))
    }

    @Test
    func `failed resource removal restores resources when publishing document only`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let path = try ScenarioResourcePath("a")
        _ = try fixture.storage.publish(ScenarioDocument(data: Data([1]), resources: [path: Data([11])]))
        var operations = FileStorageOperations()
        operations.commit = { _, _ in throw storageFault() }
        #expect(throws: FileStorageError.self) {
            try FileScenarioStorage(location: fixture.location, operations: operations)
                .publish(ScenarioDocument(data: Data([2])))
        }
        let old = try #require(try fixture.storage.load())
        #expect(old.data == Data([1]))
        #expect(try old.resource(at: path) == Data([11]))
        #expect(try fixture.entries() == ["scenario-resources", "scenario.json"])
    }

    @Test
    func `independent scenarios can publish concurrently with isolated resources`() async throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let path = try ScenarioResourcePath("body.bin")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for byte in UInt8(1)...24 {
                group.addTask {
                    let location = try ScenarioFileLocation(rootDirectory: fixture.root,
                                                            relativePath: "case-\(byte).json")
                    let storage = FileScenarioStorage(location: location)
                    _ = try storage.publish(ScenarioDocument(data: Data([byte]), resources: [path: Data([byte])]))
                    let snapshot = try #require(try storage.load())
                    #expect(try snapshot.resource(at: path) == snapshot.data)
                }
            }
            try await group.waitForAll()
        }
        #expect(try fixture.entries().count == 48)
    }

    @Test(arguments: [("case.v1.json", "case.v1-resources"), ("plain", "plain-resources")])
    func `resource directories derive stable names from the final document extension`(
        _ names: (String, String)) throws
    {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let location = try ScenarioFileLocation(rootDirectory: fixture.root, relativePath: names.0)
        let path = try ScenarioResourcePath("a")
        _ = try FileScenarioStorage(location: location)
            .publish(ScenarioDocument(data: Data([1]), resources: [path: Data([11])]))
        let file = fixture.root.appendingPathComponent(names.1).appendingPathComponent("a")
        #expect(try Data(contentsOf: file) == Data([11]))
    }

    @Test(arguments: [false, true])
    func `publication refuses a symlink or regular file at the resource directory`(symlink: Bool) throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let root = fixture.root.appendingPathComponent("scenario-resources")
        let outside = fixture.root.appendingPathComponent("outside")
        try Data([99]).write(to: outside)
        if symlink {
            try FileManager.default.createSymbolicLink(atPath: root.path, withDestinationPath: outside.path)
        } else {
            try Data([99]).write(to: root)
        }
        let document = try ScenarioDocument(data: Data([1]), resources: [ScenarioResourcePath("a"): Data()])
        #expect(throws: FileStorageError(operation: .stage, cause: .other)) {
            try fixture.storage.publish(document)
        }
        #expect(try Data(contentsOf: outside) == Data([99]))
        #expect(try fixture.entries().count == 2)
    }

    @Test
    func `read only snapshot rejects missing symlink directory and escaping resources`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        try Data([1]).write(to: fixture.location.fileURL)
        let root = fixture.root.appendingPathComponent("scenario-resources")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let outside = fixture.root.appendingPathComponent("outside")
        try Data([99]).write(to: outside)
        try Data([42]).write(to: root.appendingPathComponent("good"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path,
                                                   withDestinationPath: outside.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"),
                                                withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linkedDir").path,
                                                   withDestinationPath: fixture.root.path)
        var operations = FileStorageOperations()
        operations.write = { _, _ in Issue.record("Read attempted a write") }
        operations.createDirectory = { _ in Issue.record("Read created a directory") }
        operations.remove = { _ in Issue.record("Read attempted cleanup") }
        let snapshot = try #require(try FileScenarioStorage(location: fixture.location, operations: operations).load())
        for path in ["missing", "alias", "dir", "linkedDir/outside"] {
            #expect(throws: ScenarioResourceError.unavailable) {
                try snapshot.resource(at: ScenarioResourcePath(path))
            }
        }
        #expect(try snapshot.resource(at: ScenarioResourcePath("good")) == Data([42]))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.root.path)
        #expect(try fixture.storage.load()?.data == Data([1]))
        #expect(try snapshot.resource(at: ScenarioResourcePath("good")) == Data([42]))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    @Test(arguments: ["", "/", "/a", "a/", ".", "..", "./a", "../a", "a/.", "a/..", "a/../b", "a//b", "a\u{0}/b"])
    func `resource paths reject absolute ambiguous and escaping components`(_ path: String) {
        #expect(throws: ScenarioResourceError.invalidPath) { try ScenarioResourcePath(path) }
    }

    @Test(arguments: ["image with spaces.jpg", "café/画像.jpg", "a\\b", "a:b", "a.", "CON.txt", "%2e%2e/%2f.jpg"])
    func `literal resource names round trip without sanitizing or percent decoding`(_ name: String) throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let path = try ScenarioResourcePath(name)
        let bytes = Data([0, 255, 42])
        #expect(path.value == name)
        _ = try fixture.storage.publish(ScenarioDocument(data: Data([1]), resources: [path: bytes]))
        let snapshot = try #require(try fixture.storage.load())
        #expect(try snapshot.resource(at: path) == bytes)
        let root = fixture.root.appendingPathComponent("scenario-resources")
        let file = name.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        #expect(try Data(contentsOf: file) == bytes)
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(entries == [String(name.split(separator: "/")[0])])
    }

    @Test
    func `nonadjacent file and directory prefixes conflict`() throws {
        #expect(throws: ScenarioResourceError.conflictingResource) {
            try ScenarioDocument(data: Data(), resources: [
                ScenarioResourcePath("a"): Data(), ScenarioResourcePath("a-b"): Data(),
                ScenarioResourcePath("a/b"): Data(),
            ])
        }
    }

    @Test(arguments: [
        ("a", "A"), ("a", "a/b"), ("A", "a/b"), ("a/x", "A/y"), ("é.jpg", "É.jpg"),
        ("My Images/a.jpg", "my images/b.jpg"),
    ])
    func `resource names cannot alias or overlap`(_ pair: (String, String)) throws {
        #expect(throws: ScenarioResourceError.conflictingResource) {
            try ScenarioDocument(data: Data(), resources: [
                ScenarioResourcePath(pair.0): Data(), ScenarioResourcePath(pair.1): Data(),
            ])
        }
    }
}
