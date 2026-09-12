import DioramaCore
import Synchronization

enum ExecutionFixtures {
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

    static func definition(_ keys: [String], mode: ScenarioMode = .replay) throws -> ScenarioDefinition {
        try ScenarioDefinition(
            id: ScenarioID(rawValue: "execution"), defaultMode: mode,
            attachments: keys.map { key in
                try ScenarioAttachment(id: attachment(key)).adding(
                    SequentialTrack(id: track(key), values: preparedValues([1, 2])))
            })
    }

    static func system(
        _ key: String,
        journal: Journal,
        failPreparation: Bool = false,
        failActivation: Bool = false,
        failCleanup: Bool = false) -> ScenarioSystem
    {
        ScenarioSystem(attachmentID: attachment(key)) { context in
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
                return SystemActivation(dependency: lease) {
                    journal.events.withLock { $0.append("cleanup-" + key) }
                    if failCleanup {
                        throw SecretError(journal: journal)
                    }
                }
            }
        }
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
