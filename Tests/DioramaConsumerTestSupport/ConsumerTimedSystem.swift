import DioramaCore
import Synchronization

/// Test-only domain observations resembling location and HTTP delivery.
public enum ConsumerTimedEvent: Equatable, Sendable {
    /// An ordered batch of semantic updates.
    case batch([Int])
    /// A failure that does not end the observed session.
    case nonterminalFailure(Int)
    /// A response reached after a current application decision.
    case response(Int)
}

/// One prepared observation with a delay from its preceding boundary.
public struct ConsumerTimedObservation: Equatable, Sendable {
    /// The domain's local elapsed delay, independent of conversion time.
    public let delay: Duration
    /// The stable observation delivered at that boundary.
    public let event: ConsumerTimedEvent

    /// Creates one test-domain observation.
    public init(delay: Duration, event: ConsumerTimedEvent) {
        self.delay = delay
        self.event = event
    }
}

/// A test-domain record whose recorded horizon remains open.
/// Reaching its last observation consumes the record without ending a session.
public struct ConsumerTimedRecord: Equatable, Sendable {
    /// The stable input used by the domain's selector.
    public let input: String
    /// Observations in native observation order, with successive local delays.
    public let observations: [ConsumerTimedObservation]

    /// Creates an open test-domain record, not a production system schema.
    public init(input: String, observations: [ConsumerTimedObservation]) {
        self.input = input
        self.observations = observations
    }
}

struct TimedDraftState: Sendable {
    struct Slot: Sendable {
        let capture: LogicalTimeCapture
        var event: ConsumerTimedEvent?
    }

    let input: String
    let anchor: LogicalTimeCapture
    var slots: [Slot] = []

    func freeze(time: ExecutionTime) -> ConsumerTimedRecord? {
        do {
            let ordered = try slots.sorted { try time.capturedBefore($0.capture, $1.capture) }
            var previous = anchor
            var observations: [ConsumerTimedObservation] = []
            for slot in ordered {
                guard let event = slot.event else { return nil }
                try observations.append(ConsumerTimedObservation(
                    delay: time.elapsed(from: previous, to: slot.capture), event: event))
                previous = slot.capture
            }
            return ConsumerTimedRecord(input: input, observations: observations)
        } catch { return nil }
    }
}

struct TimedSystemState: Sendable {
    let records: HeaderlessSequentialTrackLease<ConsumerTimedRecord>
    var drafts: [RecordIdentity: TimedDraftState] = [:]
}

/// Test instrumentation survives managed-state release without retaining drafts.
final class TimedFreezeCount: Sendable {
    let count = Mutex(0)
}

/// A domain facade whose entire accumulator state is protected by Core.
public struct ConsumerTimedDraft: Sendable {
    let execution: SystemExecution<TimedSystemState>
    let freezes: TimedFreezeCount
    /// Stable identity reserved before construction.
    public let identity: RecordIdentity
    /// Number of Core freeze callbacks, including after state detaches.
    public var freezeCount: Int {
        freezes.count.withLock { $0 }
    }

    /// Reserves observation time before potentially slow stable conversion.
    public func observe() throws -> Int {
        guard !execution.isClosed else { throw ConsumerSystemFailure.closed }
        return try execution.state.withLock { state, operation in
            guard var draft = state.drafts[identity] else { throw ConsumerSystemFailure.closed }
            let capture = try operation.time.capture()
            let position = draft.slots.count
            draft.slots.append(TimedDraftState.Slot(capture: capture))
            state.drafts[identity] = draft
            return position
        }
    }

    /// Admits prepared conversion at its reserved position once, before closure.
    public func complete(_ position: Int, with event: PreparedValue<ConsumerTimedEvent>) -> Bool {
        guard !execution.isClosed else { return false }
        return (try? execution.state.withLock { state, _ in
            guard var draft = state.drafts[identity], draft.slots.indices.contains(position),
                  draft.slots[position].event == nil else { return false }
            draft.slots[position].event = event.value
            state.drafts[identity] = draft
            return true
        }) ?? false
    }
}

/// A typed domain selection facade using scoped Core operations.
public struct ConsumerTimedRecords: Sendable {
    let execution: SystemExecution<TimedSystemState>
    /// Stable record-track identity.
    public let id: TrackID
    /// The attachment's selected mode.
    public let mode: ScenarioMode
    /// Whether operation admission has closed.
    public var isClosed: Bool {
        execution.isClosed
    }

    /// Exclusively selects a record, leaving acknowledgement to domain delivery.
    public func claim<Input: Sendable>(matching input: Input,
                                       using selector: ReplaySelector<Input, ConsumerTimedRecord>) throws
        -> ReplayClaim<ConsumerTimedRecord>
    {
        try execution.state.withLock { state, operation in
            try operation.claim(on: state.records, matching: input, using: selector)
        }
    }
}

/// Public services received by a separately compiled consumer system.
public struct ConsumerTimedServices: Sendable {
    let execution: SystemExecution<TimedSystemState>
    /// Typed domain record access, serialized with all other managed state.
    public let records: ConsumerTimedRecords
    /// Execution logical-time capture and checked arithmetic.
    public var time: ExecutionTime {
        execution.time
    }

    /// Shared clock, used outside protected operations.
    public var clock: ScenarioClock {
        execution.clock
    }

    /// Ordered async delivery, registered outside protected operations.
    public var scheduling: SchedulingLease {
        execution.scheduling
    }

    /// Begins incremental capture at a domain boundary before input conversion.
    public func begin(input: String) throws -> ConsumerTimedDraft {
        let time = execution.time
        let freezes = TimedFreezeCount()
        let identity = try execution.state.withLock { state, operation in
            try operation.beginRecord(
                on: state.records, preparation: ConsumerTimedSystem.policy,
                capturing: { identity in
                    let anchor = try time.capture()
                    let prepared = try ValuePreparation<String>().prepare(
                        capturing: { input }, purpose: .recording,
                        reporter: execution.reporter, context: .record(identity))
                    state.drafts[identity] = TimedDraftState(input: prepared.value, anchor: anchor)
                    return identity
                }, freeze: { state, identity in
                    freezes.count.withLock { $0 += 1 }
                    return state.drafts.removeValue(forKey: identity)?.freeze(time: time)
                })
        }
        return ConsumerTimedDraft(execution: execution, freezes: freezes, identity: identity)
    }
}

/// Test-only domain setup using public Core APIs without a generic behavior engine.
public enum ConsumerTimedSystem {
    /// Shared identity for independently keyed timed consumer attachments.
    public static let type = ScenarioSystemType("test.consumer-timed")

    static let policy = ValuePreparation<ConsumerTimedRecord>(validate: { record in
        guard record.observations.allSatisfy({ $0.delay >= .zero }) else {
            throw ExecutionTimeIssue.negativeDelay
        }
    })

    /// Creates a reusable system with stable records and fresh execution services.
    public static func instance(key: String, values: [ConsumerTimedRecord] = []) throws
        -> ScenarioSystem<ConsumerTimedServices>
    {
        try ScenarioSystem(named: key, definition: TimedDefinition(records: TrackDefinition(
            "sessions", values: values.map { try policy.admitPrepared($0) }, preparation: policy)))
    }
}

private struct TimedDefinition: SystemDefinition {
    let systemType = ConsumerTimedSystem.type
    let records: TrackDefinition<ConsumerTimedRecord, Void>
    var tracks: [AnyTrackDefinition] {
        [records.erased]
    }

    var record: SystemModeDefinition<TimedSystemState, ConsumerTimedServices> {
        .init(makeState: { try TimedSystemState(records: $0.lease(for: records)) }, makeDependency: { execution in
            let metadata = try execution.state.withLock { state, _ in (state.records.id, state.records.mode) }
            return ConsumerTimedServices(execution: execution, records:
                ConsumerTimedRecords(execution: execution, id: metadata.0, mode: metadata.1))
        })
    }

    var replay: SystemModeDefinition<TimedSystemState, ConsumerTimedServices> {
        record
    }

    var passthrough: SystemModeDefinition<Void, ConsumerTimedServices> {
        .init(makeDependency: {
            // This synthetic domain only advertises managed capture and playback.
            throw ConsumerSystemFailure.closed
        })
    }
}
