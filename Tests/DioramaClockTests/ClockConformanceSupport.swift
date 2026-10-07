import DioramaClock
import DioramaCore
import DioramaPersistence
import Foundation
import Synchronization
import Testing

/// These helpers deliberately use only public product APIs.
enum ClockConformanceSupport {
    static func fixture(_ name: String = "clock-composition") throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func codec() throws -> JSONScenarioCodec {
        try JSONScenarioCodec(registry: PersistentSystemRegistry([DioramaClockSystem.type]))
    }

    static func file(_ bytes: Data? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diorama-f07-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("scenario.json")
        try bytes?.write(to: file)
        return file
    }

    static func offline(_ name: String) throws -> ScenarioSystem<any DioramaWallClock> {
        try DioramaClockSystem.instance(named: name) { () -> Source in
            Issue.record("Replay must not activate a live wall source")
            return Source([])
        }
    }

    final class Source: DioramaWallClock {
        private let values: [Date]
        private let reads = Mutex(0)

        init(_ seconds: [Double]) {
            values = seconds.map { Date(timeIntervalSince1970: $0) }
        }

        var count: Int {
            reads.withLock { $0 }
        }

        var now: Date {
            reads.withLock { position in
                defer { position += 1 }
                guard position < values.count else {
                    Issue.record("Unexpected live wall read")
                    return Date(timeIntervalSince1970: 0)
                }
                return values[position]
            }
        }
    }
}
