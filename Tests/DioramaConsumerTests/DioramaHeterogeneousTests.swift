import Diorama
import DioramaConsumerTestSupport
import DioramaRandom
import Foundation
import Synchronization
import Testing

struct DioramaHeterogeneousTests {
    private struct Counter: RandomNumberGenerator, Sendable {
        var value: UInt64 = 10
        mutating func next() -> UInt64 {
            defer { value += 1 }; return value
        }
    }

    @Test
    func `file setup accepts a URL with only consumer and system imports`() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let random = try DioramaRandomSystem.instance(for: "random")
        _ = try Diorama(
            file: file,
            scenarioID: "file", mode: .record,
            systems: random)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func `random and nonpersistable consumer systems retain typed declaration order`() async throws {
        let factories = Mutex(0)
        let random = try DioramaRandomSystem.instance(for: "random") {
            factories.withLock { $0 += 1 }
            return Counter()
        }.withMode(.record)
        let first = try ConsumerSequentialSystem.instance(key: .init(rawValue: "first")).withMode(.record)
        let second = try ConsumerSequentialSystem.instance(key: .init(rawValue: "second")).withMode(.record)
        let setup = try Diorama(
            scenarioID: "heterogeneous", mode: .passthrough,
            systems: first, random, second)
        #expect(factories.withLock { $0 } == 0)
        for _ in 0..<2 {
            let result = try await setup.execute { first, random, second in
                var random = random
                #expect(first !== second)
                #expect(random.next() == 10)
                #expect(random.next() == 11)
                return try [first.next { ConsumerStableValue(1) }, second.next { ConsumerStableValue(2) }]
            }
            #expect(result.body == [ConsumerStableValue(1), ConsumerStableValue(2)])
            #expect(result.finalization.report.diagnostics.isEmpty)
        }
        #expect(factories.withLock { $0 } == 2)
    }
}
