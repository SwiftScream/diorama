import DioramaCore
import DioramaPersistence
@testable import DioramaRandom
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
        key: String, allowsUnclaimedReplayRecords: Bool = false)
        throws -> ScenarioSystem<StartupDependency>
    {
        try ScenarioSystem(named: key, definition: Definition(probe: self),
                           allowsUnclaimedReplayRecords: allowsUnclaimedReplayRecords)
    }

    private struct Definition: SystemDefinition {
        let probe: StartupProbe
        let systemType = DioramaRandomSystem.type
        let values = SystemTrack<UInt64, Void>("values")
        var tracks: [AnySystemTrack] {
            [values.erased]
        }

        func validate(in context: borrowing SystemValidationContext) throws {
            probe.state.withLock { $0.preparations += 1 }
            if context.mode != .passthrough {
                try context.validate(values) { track in
                    if probe.failValidation, !track.records.isEmpty {
                        throw StartupFault()
                    }
                }
            }
        }

        func makeRecordState(in context: borrowing SystemStateContext) throws
            -> HeaderlessSequentialTrackLease<UInt64>
        {
            probe.state.withLock { $0.activations += 1 }
            return try context.lease(for: values)
        }

        func makeReplayState(in context: borrowing SystemStateContext) throws
            -> HeaderlessSequentialTrackLease<UInt64>
        {
            try makeRecordState(in: context)
        }

        func makeRecordDependency(using runtime: SystemRuntime<HeaderlessSequentialTrackLease<UInt64>>)
            -> StartupDependency
        {
            .managed(runtime)
        }

        func makeReplayDependency(using runtime: SystemRuntime<HeaderlessSequentialTrackLease<UInt64>>)
            -> StartupDependency
        {
            .managed(runtime)
        }

        func makePassthroughDependency() -> StartupDependency {
            probe.state.withLock { $0.activations += 1 }
            return .passthrough
        }
    }
}

enum StartupDependency: Sendable {
    case managed(SystemRuntime<HeaderlessSequentialTrackLease<UInt64>>)
    case passthrough

    func report(_ issue: DiagnosticIssue, recordingImpact: RecordingImpact = .none) -> Bool {
        guard case let .managed(runtime) = self else { return false }
        return (try? runtime.withActiveState { lease, operation in
            operation.report(on: lease, issue, recordingImpact: recordingImpact)
        }) ?? false
    }

    func consumeNext() throws -> UInt64 {
        guard case let .managed(runtime) = self else { throw StartupFault() }
        return try runtime.withActiveState { lease, operation in try operation.consumeNext(on: lease) }
    }

    func record(capturing capture: () throws -> UInt64, preparation: ValuePreparation<UInt64>) throws {
        guard case let .managed(runtime) = self else {
            _ = try capture()
            return
        }
        _ = try runtime.withActiveState { lease, operation in
            try operation.record(on: lease, capturing: capture, preparation: preparation)
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
