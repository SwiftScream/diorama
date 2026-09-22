import DioramaCore
import DioramaPersistence
import DioramaRandom
import Foundation
import Synchronization

final class StartupProbe: Sendable {
    private struct State: Sendable {
        var preparations = 0
        var activations = 0
    }

    private let failValidation: Bool
    private let state = Mutex(State())

    init(failValidation: Bool = false) {
        self.failValidation = failValidation
    }

    var preparationCount: Int {
        state.withLock { $0.preparations }
    }

    var activationCount: Int {
        state.withLock { $0.activations }
    }

    func system(
        key: String, allowsUnusedReplayRecords: Bool = false)
        throws -> ScenarioSystem<SequentialTrackLease<UInt64>>
    {
        let attachmentKey = AttachmentKey(rawValue: key)
        let trackID = DioramaRandomSystem.trackID(for: attachmentKey)
        let attachment = try ScenarioAttachment(
            id: DioramaRandomSystem.attachmentID(for: attachmentKey)).adding(SequentialTrack<UInt64>(id: trackID))
        return try ScenarioSystem(type: DioramaRandomSystem.type, attachment: attachment,
                                  allowsUnusedReplayRecords: allowsUnusedReplayRecords)
        { [self] context in
            state.withLock { $0.preparations += 1 }
            let preparation = ValuePreparation<UInt64>(validate: { [failValidation] _ in
                if failValidation {
                    throw StartupFault()
                }
            })
            let lease = try context.lease(for: trackID, preparation: preparation)
            return PreparedSystem { [self] in
                state.withLock { $0.activations += 1 }
                return ActivatedSystem(dependency: lease, deactivate: {})
            }
        }
    }
}

final class StartupStorage: ScenarioDocumentStorage, Sendable {
    private struct State: Sendable {
        var reads = 0
        var writes = 0
    }

    private let document: Data?
    private let readError: Bool
    private let state = Mutex(State())

    init(document: Data? = nil, readError: Bool = false) {
        self.document = document
        self.readError = readError
    }

    var readCount: Int {
        state.withLock { $0.reads }
    }

    var writeCount: Int {
        state.withLock { $0.writes }
    }

    func load() throws -> Data? {
        state.withLock { $0.reads += 1 }
        if readError {
            throw StartupFault()
        }
        return document
    }

    func publish(_: Data) throws -> DocumentPublication {
        state.withLock { $0.writes += 1 }
        return DocumentPublication()
    }
}

struct StartupFault: Error {}

func randomRepository(storage: any ScenarioDocumentStorage) throws -> JSONScenarioRepository {
    try JSONScenarioRepository(
        codec: JSONScenarioCodec(registry: PersistentSystemRegistry([
            DioramaRandomSystem.type,
        ])),
        storage: storage)
}

func failureStorage(_ kind: String) throws -> StartupStorage {
    switch kind {
    case "missing": StartupStorage()
    case "unreadable": StartupStorage(readError: true)
    case "invalid": StartupStorage(document: Data())
    case "envelope": try StartupStorage(document: persistedFixture("unsupported-envelope-version"))
    default: try StartupStorage(document: persistedFixture("unsupported-random-version"))
    }
}

func loadProblem(_ result: ScenarioLoadResult) -> ScenarioBaselineProblem? {
    switch result {
    case .loaded: nil
    case .missing: .missing
    case .unreadable: .unreadable
    case .invalidDocument: .invalidDocument
    case .incompatibleEnvelope: .incompatibleEnvelope
    case .incompatibleSystem: .incompatibleSystem
    }
}
