import DioramaCore
import Synchronization

enum ExecutionFixtures {
    static let type = ScenarioSystemType("consumer")

    final class Journal: Sendable {
        let events = Mutex<[String]>([])
        let leases = Mutex<[SequentialTrackLease<Int>]>([])
        let descriptions = Mutex(0)
    }

    static func attachment(_ key: String) -> AttachmentID {
        AttachmentID(systemTypeID: SystemTypeID(rawValue: "consumer"), key: AttachmentKey(rawValue: key))
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

    static func system(
        _ key: String,
        journal: Journal,
        mode: ScenarioMode? = nil,
        failPreparation: Bool = false,
        failActivation: Bool = false,
        failCleanup: Bool = false) throws -> AnyScenarioSystem
    {
        try AnyScenarioSystem(ScenarioSystem(
            type: ExecutionFixtures.type,
            attachment: ScenarioAttachment(id: attachment(key)))
        { context in
            journal.events.withLock { $0.append("prepare-" + key) }
            let lease = try context.lease(for: track(key), preparation: ValuePreparation<Int>())
            journal.leases.withLock { $0.append(lease) }
            if failPreparation {
                throw SecretError(journal: journal)
            }
            return PreparedSystem {
                journal.events.withLock { $0.append("activate-" + key) }
                if failActivation {
                    throw SecretError(journal: journal)
                }
                return ActivatedSystem(dependency: lease) {
                    journal.events.withLock { $0.append("cleanup-" + key) }
                    if failCleanup {
                        throw SecretError(journal: journal)
                    }
                }
            }
        }.withMode(mode))
    }

    static func dependencyKey<Dependency: Sendable>(
        _ key: String,
        as _: Dependency.Type = Dependency.self) -> DependencyKey<Dependency>
    {
        DependencyKey(attachmentID: attachment(key))
    }

    struct SecretError: Error, CustomStringConvertible {
        let journal: Journal
        var description: String {
            journal.descriptions.withLock { $0 += 1 }
            return "SECRET-LIFECYCLE-ERROR"
        }
    }

    final class Probe: Sendable {
        let onRelease: @Sendable () -> Void
        init(_ onRelease: @escaping @Sendable () -> Void) {
            self.onRelease = onRelease
        }

        deinit { onRelease() }
    }
}
