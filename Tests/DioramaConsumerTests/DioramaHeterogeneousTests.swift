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
    func `complete nonpersistable output replays without returning observations from the body`() async throws {
        let random = try DioramaRandomSystem.instance(named: "random") { Counter() }
        let consumer = try ConsumerSequentialSystem.instance(key: .init(rawValue: "consumer"))
        let recording = try await Diorama(scenarioID: "record", mode: .record, systems: random, consumer)
            .execute { random, consumer in
                var random = random
                _ = random.next()
                _ = random.next()
                _ = try consumer.next { ConsumerStableValue(42) }
            }
        let definition = try #require(recording.definition)
        guard case .notRequested = recording.publication else {
            Issue.record("In-memory run requested storage"); return
        }
        let replay = try Diorama(definition: definition, scenarioID: "replay", mode: .replay,
                                 systems: random, consumer)
        for _ in 0..<2 {
            let result = try await replay.execute { random, consumer async throws in
                var random = random
                #expect(random.next() == 10)
                #expect(random.next() == 11)
                #expect(try consumer.next {
                    Issue.record("Replay consulted live consumer")
                    return ConsumerStableValue(-1)
                } == ConsumerStableValue(42))
            }
            #expect(result.finalization.report.diagnostics.isEmpty)
        }
    }

    @Test
    func `file setup accepts a URL with only consumer and system imports`() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let random = try DioramaRandomSystem.instance(named: "random")
        _ = try Diorama(
            file: file,
            scenarioID: "file", mode: .record,
            systems: random)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func `random and nonpersistable consumer systems retain typed declaration order`() async throws {
        let factories = Mutex(0)
        let random = try DioramaRandomSystem.instance(named: "random") {
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
