@testable import DioramaPersistence
import Foundation
import Testing

struct FileStorageFixture {
    let root: URL
    let location: ScenarioFileLocation

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diorama-c03-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        location = try ScenarioFileLocation(rootDirectory: root, relativePath: "scenario.json")
    }

    var storage: FileScenarioStorage {
        FileScenarioStorage(location: location)
    }

    func entries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    func remove() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try FileManager.default.removeItem(at: root)
    }
}

func storageFault(_ code: Int = 5) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: code,
            userInfo: [NSLocalizedDescriptionKey: "secret-native-path-and-payload"])
}

func persistedFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}
