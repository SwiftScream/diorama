import Diorama
import DioramaConsumerTestSupport
import DioramaCore
import DioramaPersistence
import DioramaRandom
import Foundation
import Synchronization
import Testing

struct PersistedConsumerConformanceTests {
    private struct Counter: RandomNumberGenerator, Sendable {
        var value: UInt64

        mutating func next() -> UInt64 {
            defer { value += 1 }
            return value
        }
    }

    @Test
    func `public consumer codec and two random domains publish deterministic files`() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = try DioramaRandomSystem.instance(named: "first") { Counter(value: 10) }
        let second = try DioramaRandomSystem.instance(named: "second") { Counter(value: 100) }
        let consumerKey = AttachmentKey(rawValue: "consumer")
        let consumer = try ConsumerPersistedSystem.instance(key: consumerKey)
        let record = try Diorama(file: file, scenarioID: "persistent-consumer", mode: .record,
                                 systems: first, second, consumer)
        var firstPublication: Data?

        for _ in 0..<2 {
            let result = try await record.execute { first, second, consumer async throws in
                async let firstValues = draw(first, count: 32)
                async let secondValues = draw(second, count: 32)
                let (recordedFirst, recordedSecond) = await (firstValues, secondValues)
                let value = try consumer.next { ConsumerStableValue(7) }
                return (recordedFirst, recordedSecond, value)
            }
            #expect(result.body.0 == Array(UInt64(10)..<42))
            #expect(result.body.1 == Array(UInt64(100)..<132))
            #expect(result.body.2 == ConsumerStableValue(7))
            #expect(result.finalization.report.diagnostics.isEmpty)
            #expect(result.finalization.usage.map(\.mode) == [.record, .record, .record])
            #expect(result.definition != nil)
            guard case .published = result.publication else { Issue.record("Expected file publication"); return }
            let published = try Data(contentsOf: file)
            if let firstPublication {
                #expect(published == firstPublication)
            } else {
                firstPublication = published
            }
        }

        let bytes = try Data(contentsOf: file)
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([first.type, second.type, consumer.type]))
        let decoded = try codec.decode(bytes)
        let consumerAttachment = try #require(decoded.attachment(for: consumerKey))
        let maybeConsumerTrack = try consumerAttachment.track(
            ConsumerPersistedSystem.trackID(for: consumerKey), as: ConsumerStableValue.self)
        let consumerTrack = try #require(maybeConsumerTrack)
        #expect(consumerTrack.records.map(\.value) == [ConsumerStableValue(7)])
        #expect(try codec.encode(decoded) == bytes)
    }

    @Test
    func `file replay starts fresh cursors and never creates live sources`() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let bytes = try fixture("consumer-three-track")
        try bytes.write(to: file)
        let consumer = try ConsumerPersistedSystem.instance(key: AttachmentKey(rawValue: "consumer"))
        let factoryCalls = Mutex(0)
        let replayFirst = try DioramaRandomSystem.instance(named: "first") {
            factoryCalls.withLock { $0 += 1 }
            return Counter(value: 900)
        }
        let replaySecond = try DioramaRandomSystem.instance(named: "second") {
            factoryCalls.withLock { $0 += 1 }
            return Counter(value: 900)
        }
        let replay = try Diorama(file: file, scenarioID: "persistent-consumer", mode: .replay,
                                 systems: replayFirst, replaySecond, consumer)
        for _ in 0..<2 {
            let result = try await replay.execute { first, second, consumer in
                var first = first
                var second = second
                let firstValue = first.next()
                let secondValue = second.next()
                let consumerValue = try consumer.next {
                    Issue.record("Replay consulted the consumer live dependency")
                    return ConsumerStableValue(-1)
                }
                return (firstValue, secondValue, consumerValue)
            }
            #expect(result.body.0 == 10)
            #expect(result.body.1 == 100)
            #expect(result.body.2 == ConsumerStableValue(7))
            #expect(result.finalization.evaluate(.allRecordingsUsed).isSatisfied)
            #expect(result.finalization.report.diagnostics.isEmpty)
            guard case .notRequested = result.publication else { Issue.record("Replay wrote storage"); return }
        }
        #expect(factoryCalls.withLock { $0 } == 0)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test
    func `mixed modes preserve replay and passthrough content while replacing recorded domain`() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = try DioramaRandomSystem.instance(named: "first") { Counter(value: 10) }
        let second = try DioramaRandomSystem.instance(named: "second") { Counter(value: 100) }
        let consumerKey = AttachmentKey(rawValue: "consumer")
        let consumer = try ConsumerPersistedSystem.instance(key: consumerKey)
        let original = try await Diorama(file: file, scenarioID: "mixed", mode: .record,
                                         systems: first, second, consumer)
            .execute { first, second, consumer in
                var first = first
                var second = second
                _ = first.next()
                _ = second.next()
                _ = try consumer.next { ConsumerStableValue(7) }
            }
        guard case .published = original.publication else { Issue.record("Expected baseline publication"); return }
        #expect(try Data(contentsOf: file) == fixture("consumer-three-track"))

        let newSecond = try DioramaRandomSystem.instance(named: "second") { Counter(value: 500) }
        let mixed = try await Diorama(file: file, scenarioID: "mixed", mode: .passthrough,
                                      systems: first.withMode(.replay), newSecond.withMode(.record), consumer)
            .execute { first, second, consumer in
                var first = first
                var second = second
                let firstValue = first.next()
                let secondValue = second.next()
                let consumerValue = try consumer.next { ConsumerStableValue(99) }
                return (firstValue, secondValue, consumerValue)
            }
        #expect(mixed.body.0 == 10)
        #expect(mixed.body.1 == 500)
        #expect(mixed.body.2 == ConsumerStableValue(99))
        #expect(mixed.finalization.usage.map(\.mode) == [.replay, .record, .passthrough])
        guard case .published = mixed.publication else { Issue.record("Expected mixed publication"); return }

        let replay = try await Diorama(file: file, scenarioID: "mixed", mode: .replay,
                                       systems: first, newSecond, consumer)
            .execute { first, second, consumer in
                var first = first
                var second = second
                return try (first.next(), second.next(), consumer.next { ConsumerStableValue(-1) })
            }
        #expect(replay.body.0 == 10)
        #expect(replay.body.1 == 500)
        #expect(replay.body.2 == ConsumerStableValue(7))
        #expect(replay.finalization.evaluate(.allRecordingsUsed).isSatisfied)
        guard case .notRequested = replay.publication else { Issue.record("Replay wrote storage"); return }
    }

    @Test
    func `file passthrough uses live sources without changing stored content`() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let bytes = try fixture("consumer-three-track")
        try bytes.write(to: file)
        let first = try DioramaRandomSystem.instance(named: "first") { Counter(value: 10) }
        let second = try DioramaRandomSystem.instance(named: "second") { Counter(value: 500) }
        let consumer = try ConsumerPersistedSystem.instance(key: AttachmentKey(rawValue: "consumer"))
        let passthrough = try await Diorama(file: file, scenarioID: "mixed", mode: .passthrough,
                                            systems: first, second, consumer)
            .execute { first, second, consumer in
                var first = first
                var second = second
                return try (first.next(), second.next(), consumer.next { ConsumerStableValue(123) })
            }
        #expect(passthrough.body.0 == 10)
        #expect(passthrough.body.1 == 500)
        #expect(passthrough.body.2 == ConsumerStableValue(123))
        #expect(passthrough.finalization.usage.map(\.mode) == [.passthrough, .passthrough, .passthrough])
        guard case .notRequested = passthrough.publication else { Issue.record("Passthrough wrote storage"); return }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test
    func `persisted replay reports unused positions and deterministic exhaustion`() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let random = try DioramaRandomSystem.instance(named: "random") { Counter(value: 41) }
        let consumer = try ConsumerPersistedSystem.instance(key: AttachmentKey(rawValue: "consumer"))
        let recording = try await Diorama(file: file, scenarioID: "usage", mode: .record,
                                          systems: random, consumer)
            .execute { random, consumer in
                var random = random
                _ = random.next()
                _ = random.next()
                _ = try consumer.next { ConsumerStableValue(9) }
            }
        guard case .published = recording.publication else { Issue.record("Expected file publication"); return }
        let bytes = try Data(contentsOf: file)

        let unused = try await Diorama(file: file, scenarioID: "usage", mode: .replay,
                                       systems: random, consumer)
            .execute { random, _ in
                var random = random
                return random.next()
            }
        #expect(unused.body == 41)
        #expect(unused.finalization.usage.map { $0.tracks[0].unusedRecords.count } == [1, 1])
        #expect(unused.finalization.evaluate(.allRecordingsUsed).failures.count == 2)
        #expect(unused.finalization.report.diagnostics.isEmpty)

        let exhausted = try await Diorama(file: file, scenarioID: "usage", mode: .replay,
                                          systems: random, consumer)
            .execute { random, consumer in
                var random = random
                let firstValue = random.next()
                let secondValue = random.next()
                let exhaustedValue = random.next()
                let consumerValue = try consumer.next { ConsumerStableValue(-1) }
                return (firstValue, secondValue, exhaustedValue, consumerValue)
            }
        #expect(exhausted.body.0 == 41)
        #expect(exhausted.body.1 == 42)
        #expect(exhausted.body.2 == 0)
        #expect(exhausted.body.3 == ConsumerStableValue(9))
        #expect(exhausted.finalization.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.replayExhausted(availableCount: 2)),
        ])
        #expect(exhausted.finalization.report.diagnostics[0].diagnostic.context.recordIdentity?.sequence == 2)
        #expect(exhausted.finalization.evaluate(.allRecordingsUsed).isSatisfied)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test
    func `consumer payload rejects unknown fields and unsupported versions`() throws {
        let first = try DioramaRandomSystem.instance(named: "first")
        let second = try DioramaRandomSystem.instance(named: "second")
        let consumer = try ConsumerPersistedSystem.instance(key: AttachmentKey(rawValue: "consumer"))
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([first.type, second.type, consumer.type]))
        let source = try #require(String(data: fixture("consumer-three-track"), encoding: .utf8))
        let withUnknownField = source.replacingOccurrences(
            of: "\"values\" : [\n          7",
            with: "\"unexpected\" : 1,\n        \"values\" : [\n          7")
        #expect(withUnknownField != source)
        #expect(throws: PersistedScenarioCodingError.self) {
            try codec.decode(Data(withUnknownField.utf8))
        }

        let withUnsupportedVersion = source.replacingOccurrences(
            of: "\"schemaVersion\" : 1,\n      \"type\" : \"test.consumer-persisted\"",
            with: "\"schemaVersion\" : 2,\n      \"type\" : \"test.consumer-persisted\"")
        #expect(withUnsupportedVersion != source)
        #expect(throws: PersistenceDispatchError.self) {
            try codec.decode(Data(withUnsupportedVersion.utf8))
        }
    }

    private func draw(_ generator: any RandomNumberGenerator & Sendable, count: Int) -> [UInt64] {
        var generator = generator
        return (0..<count).map { _ in generator.next() }
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory.appendingPathComponent("scenario.json")
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}
