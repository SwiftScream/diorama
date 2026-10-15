import Diorama
import DioramaCore
import Synchronization

enum DioramaFixtures {
    static let type = ScenarioSystemType("consumer")

    final class Journal: Sendable {
        let events = Mutex<[String]>([])
    }

    static func attachment(_ key: String) -> AttachmentID {
        AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: key))
    }

    static func track(_ key: String) -> TrackID {
        TrackID(attachmentID: attachment(key), key: TrackKey(rawValue: "values"))
    }

    static func definition(_ keys: [String]) throws -> ScenarioDefinition {
        try ScenarioDefinition(attachments: keys.map { key in
            try ScenarioAttachment(id: attachment(key)).adding(
                SequentialTrack(id: track(key), values: preparedValues([1, 2])))
        })
    }
}

func preparedValues<Value: Sendable>(_ values: [Value]) throws -> [PreparedValue<Value>] {
    let reporter = try DiagnosticReporter(
        scenarioID: ScenarioID(rawValue: "fixtures"), definition: ScenarioDefinition())
    let preparation = ValuePreparation<Value>()
    return try values.map { value in
        try preparation.prepare(capturing: { value }, purpose: .replay, reporter: reporter)
    }
}

/// Track-free fixture for consumer admission and retained-report lifecycle tests.
struct LifecycleDefinition<Dependency: Sendable>: SystemDefinition {
    let systemType = DioramaFixtures.type
    var validation: @Sendable () throws -> Void = {}
    let factory: @Sendable () throws -> Dependency
    var cleanup: @Sendable () throws -> Void = {}

    func validate(in _: borrowing SystemValidationContext) throws {
        try validation()
    }

    var record: SystemModeDefinition<Void, Dependency> {
        .init(makeState: makeRecordState, makeDependency: makeRecordDependency, cleanUp: cleanUpRecord)
    }

    var replay: SystemModeDefinition<Void, Dependency> {
        .init(makeState: makeReplayState, makeDependency: makeReplayDependency, cleanUp: cleanUpReplay)
    }

    var passthrough: SystemModeDefinition<Void, Dependency> {
        .init(makeDependency: makePassthroughDependency)
    }

    func makeRecordState(in _: borrowing SystemStateContext) {
        ()
    }

    func makeReplayState(in _: borrowing SystemStateContext) {
        ()
    }

    func makeRecordDependency(using _: SystemExecution<Void>) throws -> Dependency {
        try factory()
    }

    func makeReplayDependency(using _: SystemExecution<Void>) throws -> Dependency {
        try factory()
    }

    func makePassthroughDependency(using _: SystemExecution<Void>) throws -> Dependency {
        try factory()
    }

    func cleanUpRecord(using _: borrowing SystemLifecycleContext<Void>,
                       dependency _: Dependency?) -> SystemCleanupResult
    {
        do {
            try cleanup()
            return .completed
        } catch {
            return .failed(DiagnosticLabel("fixture-cleanup-failed"))
        }
    }

    func cleanUpReplay(using lifecycle: borrowing SystemLifecycleContext<Void>,
                       dependency: Dependency?) -> SystemCleanupResult
    {
        cleanUpRecord(using: lifecycle, dependency: dependency)
    }
}
