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

/// An external domain accumulator that separates observation from conversion.
public final class ConsumerTimedDraft: Sendable {
    private struct Slot {
        let capture: LogicalTimeCapture
        var event: ConsumerTimedEvent?
    }

    private struct State {
        var time: ExecutionTime?
        var anchor: LogicalTimeCapture?
        var isClosed: (@Sendable () -> Bool)?
        var input: String?
        var slots: [Slot] = []
        var freezeCount = 0
    }

    private let state: Mutex<State>

    /// The stable identity reserved before this draft is constructed.
    public let identity: RecordIdentity

    /// The number of freeze callbacks received from Core.
    public var freezeCount: Int {
        state.withLock { $0.freezeCount }
    }

    init(identity: RecordIdentity, input: PreparedValue<String>, anchor: LogicalTimeCapture,
         time: ExecutionTime, isClosed: @escaping @Sendable () -> Bool)
    {
        self.identity = identity
        state = Mutex(State(time: time, anchor: anchor, isClosed: isClosed, input: input.value))
    }

    /// Reserves observation time before potentially slow stable conversion.
    /// Concurrent reservations sort by capture order when the draft freezes.
    public func observe() throws -> Int {
        let time = try state.withLock { state in
            guard let time = state.time else { throw ConsumerSystemFailure.closed }
            return time
        }
        let capture = try time.capture()
        return try state.withLock { state in
            guard state.time != nil else { throw ConsumerSystemFailure.closed }
            let position = state.slots.count
            state.slots.append(Slot(capture: capture))
            return position
        }
    }

    /// Commits a prepared observation to its reserved position exactly once.
    /// Rejects completion after admission closes, including before freeze.
    public func complete(_ position: Int, with event: PreparedValue<ConsumerTimedEvent>) -> Bool {
        guard let isClosed = state.withLock({ $0.isClosed }), !isClosed() else { return false }
        return state.withLock { state in
            guard state.time != nil, state.slots.indices.contains(position),
                  state.slots[position].event == nil else { return false }
            state.slots[position].event = event.value
            return true
        }
    }

    func freeze() -> ConsumerTimedRecord? {
        let detached = state.withLock { state in
            let detached = state
            state = State(freezeCount: state.freezeCount + 1)
            return detached
        }
        guard let time = detached.time, var previous = detached.anchor, let input = detached.input else { return nil }
        do {
            let ordered = try detached.slots.sorted { try time.capturedBefore($0.capture, $1.capture) }
            var observations: [ConsumerTimedObservation] = []
            for slot in ordered {
                guard let event = slot.event else { return nil }
                try observations.append(ConsumerTimedObservation(
                    delay: time.elapsed(from: previous, to: slot.capture), event: event))
                previous = slot.capture
            }
            return ConsumerTimedRecord(input: input, observations: observations)
        } catch {
            return nil
        }
    }
}

/// Public services received by a separately compiled consumer system.
public struct ConsumerTimedServices: Sendable {
    /// The typed record lease, shared across capture and selection APIs.
    public let records: HeaderlessSequentialTrackLease<ConsumerTimedRecord>
    /// The execution's shared logical-time service.
    public let time: ExecutionTime
    /// The same runtime clock exposed to scoped application code.
    public let clock: ScenarioClock
    /// The attachment's scheduling service; delivery isolation stays external.
    public let scheduling: SchedulingLease

    /// Begins incremental capture at a domain boundary before input conversion.
    public func begin(input: String) throws -> ConsumerTimedDraft {
        try records.beginRecord(preparation: ConsumerTimedSystem.policy, capturing: { identity in
            let anchor = try time.capture()
            let prepared = try ValuePreparation<String>().prepare(
                capturing: { input }, purpose: .recording, reporter: records.reporter, context: .record(identity))
            return ConsumerTimedDraft(identity: identity, input: prepared, anchor: anchor,
                                      time: time, isClosed: { records.isClosed })
        }, freeze: { $0.freeze() })
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
        let id = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: key))
        let trackID = TrackID(attachmentID: id, key: TrackKey(rawValue: "sessions"))
        let values = try values.map { try policy.admitPrepared($0) }
        let attachment = try ScenarioAttachment(id: id).adding(SequentialTrack(id: trackID, values: values))
        return try ScenarioSystem(type: type, attachment: attachment) { context in
            let records = try context.lease(for: trackID, preparation: policy)
            let dependency = ConsumerTimedServices(
                records: records, time: context.time, clock: context.clock, scheduling: context.scheduling)
            return PreparedSystem { ActivatedSystem(dependency: dependency, deactivate: {}) }
        }
    }
}
