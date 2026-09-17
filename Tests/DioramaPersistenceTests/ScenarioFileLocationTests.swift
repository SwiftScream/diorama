import DioramaPersistence
import Foundation
import Testing

struct ScenarioFileLocationTests {
    @Test(arguments: ["", "/absolute.json", "../escape", "a/../b", "./file", "a//b", "a/", "a\\b", "a\0b", "a\nb"])
    func `rejects unsafe relative paths without leaking their text`(path: String) throws {
        #expect(throws: ScenarioFileLocationError.invalidRelativePath) {
            _ = try ScenarioFileLocation(rootDirectory: URL(fileURLWithPath: "/fixtures"), relativePath: path)
        }
    }

    @Test(arguments: [
        "https://example.com/fixtures", "file://remote/fixtures", "file:///fixtures?q=x", "file:///fixtures#x",
    ])
    func `rejects nonlocal and decorated roots`(root: String) throws {
        let url = try #require(URL(string: root))
        #expect(throws: ScenarioFileLocationError.invalidRoot) {
            _ = try ScenarioFileLocation(rootDirectory: url, relativePath: "scenario.json")
        }
    }

    @Test
    func `literal Unicode spaces and percent names retain deterministic paths`() throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let path = "café #1 %2F.json"
        let location = try ScenarioFileLocation(rootDirectory: fixture.root, relativePath: path)
        #expect(location.relativePath == path)
        #expect(location.fileURL.lastPathComponent == path)
        #expect(location.fileURL.deletingLastPathComponent().standardizedFileURL == fixture.root.standardizedFileURL)
        _ = try FileScenarioStorage(location: location).publish(Data([7]))
        #expect(try fixture.entries() == [path])
        #expect(try FileScenarioStorage(location: location).load() == Data([7]))
    }

    @Test
    func `nested paths and extension choices are explicit`() throws {
        let root = URL(fileURLWithPath: "/fixtures", isDirectory: true)
        let location = try ScenarioFileLocation(rootDirectory: root, relativePath: "group/scenario")
        #expect(location.fileURL.path == "/fixtures/group/scenario")
        #expect(try location == ScenarioFileLocation(rootDirectory: root, relativePath: "group/scenario"))
    }
}
