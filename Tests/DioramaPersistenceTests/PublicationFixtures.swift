import DioramaCore
import DioramaPersistence
import DioramaRandom
import Foundation
import Synchronization
import Testing

final class PublicationStorage: ScenarioDocumentStorage {
    private struct State: Sendable {
        var document: Data?
        var reads = 0
        var writes = 0
    }

    private let state: Mutex<State>
    private let beforeCommit: @Sendable () throws -> Void

    init(document: Data? = nil, beforeCommit: @escaping @Sendable () throws -> Void = {}) {
        state = Mutex(State(document: document))
        self.beforeCommit = beforeCommit
    }

    var document: Data? {
        state.withLock { $0.document }
    }

    var readCount: Int {
        state.withLock { $0.reads }
    }

    var writeCount: Int {
        state.withLock { $0.writes }
    }

    func load() -> Data? {
        state.withLock { state in
            state.reads += 1
            return state.document
        }
    }

    func publish(_ document: Data) throws -> DocumentPublication {
        state.withLock { $0.writes += 1 }
        try beforeCommit()
        state.withLock { $0.document = document }
        return DocumentPublication()
    }
}

enum PublicationFixtures {
    struct Payload: Codable, Sendable {
        let values: [UInt64]
    }

    static func codec() throws -> JSONScenarioCodec {
        let random = try DioramaRandomSystem.instance(named: "fixture")
        return try JSONScenarioCodec(registry: PersistentSystemRegistry([random.type]))
    }

    static func definition(_ entries: [(String, [UInt64])]) throws -> ScenarioDefinition {
        try ScenarioDefinition(attachments: entries.map { key, values in
            let layout = try DioramaRandomSystem.instance(named: key).attachment
            return try ScenarioAttachment(id: layout.id).adding(
                SequentialTrack(id: layout.trackIDs[0],
                                values: PersistentSystemRegistryTests.prepared(values)))
        })
    }

    static func values(_ key: String, in definition: ScenarioDefinition) throws -> [UInt64] {
        let layout = try DioramaRandomSystem.instance(named: key).attachment
        let attachment = try #require(definition.attachment(for: layout.id.key))
        return try #require(try attachment.track(layout.trackIDs[0], as: UInt64.self))
            .records.map(\.value)
    }

    enum Failure: Error, Equatable {
        case body
        case encoding
        case storage
    }
}
