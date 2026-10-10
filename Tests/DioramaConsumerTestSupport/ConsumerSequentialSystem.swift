import DioramaCore

/// A stable consumer-owned value with no persistence conformance.
public struct ConsumerStableValue: Equatable, Sendable {
    /// The semantic integer carried by this test system.
    public let number: Int

    /// Creates a consumer-owned stable value.
    ///
    /// - Parameter number: The value exposed by the synchronous dependency.
    public init(_ number: Int) {
        self.number = number
    }
}

/// A consumer-system error for use after its execution lifetime closes.
public enum ConsumerSystemFailure: Error, Equatable, Sendable {
    /// The dependency's execution has finished or rolled back.
    case closed
}

/// A test-only synchronous dependency built entirely from public core APIs.
public final class ConsumerSequentialDependency: Sendable {
    /// The effective whole-attachment mode supplied during preparation.
    public var mode: ScenarioMode {
        switch behavior {
        case let .managed(_, mode): mode
        case .passthrough: .passthrough
        }
    }

    /// Whether the execution has closed this dependency's track lease.
    public var isClosed: Bool {
        switch behavior {
        case let .managed(runtime, _): runtime.isClosed
        case .passthrough: false
        }
    }

    private enum Behavior: Sendable {
        case managed(SystemRuntime<HeaderlessSequentialTrackLease<ConsumerStableValue>>, ScenarioMode)
        case passthrough
    }

    private let behavior: Behavior

    init() {
        behavior = .passthrough
    }

    init(runtime: SystemRuntime<HeaderlessSequentialTrackLease<ConsumerStableValue>>, mode: ScenarioMode) {
        behavior = .managed(runtime, mode)
    }

    /// Performs one synchronous dependency operation under the attachment mode.
    ///
    /// Record mode reserves and prepares the live value, replay mode returns the
    /// next recorded value without evaluating `liveValue`, and passthrough
    /// returns the live value without using track content.
    ///
    /// - Parameter liveValue: A live value evaluated only in record or
    ///   passthrough mode. Passthrough retains its native lifetime after finish.
    /// - Returns: The live or replayed stable value selected by the mode.
    /// - Throws: Public sequential-operation evidence or ``ConsumerSystemFailure/closed``.
    public func next(capturing liveValue: () -> ConsumerStableValue) throws -> ConsumerStableValue {
        guard case let .managed(runtime, mode) = behavior else { return liveValue() }
        do {
            return try runtime.withActiveState { lease, operation in
                if mode == .replay {
                    return try operation.consumeNext(on: lease)
                }
                var observation: ConsumerStableValue?
                try operation.record(on: lease, capturing: {
                    let value = liveValue()
                    observation = value
                    return value
                }, preparation: ValuePreparation<ConsumerStableValue>())
                guard let observation else { preconditionFailure("Successful capture supplies one value") }
                return observation
            }
        } catch {
            if runtime.isClosed {
                throw ConsumerSystemFailure.closed
            }
            throw error
        }
    }

    /// Contributes a capability-defined unused-record verification fact.
    ///
    /// This proves public diagnostic participation. Automatic sequential usage
    /// accounting remains a core finalization responsibility in plan unit B08.
    ///
    /// - Returns: Whether the fact entered the active execution report.
    @discardableResult
    public func reportUnusedRecord() -> Bool {
        guard case let .managed(runtime, _) = behavior else { return false }
        return (try? runtime.withActiveState { lease, operation in
            operation.report(on: lease, .system(DiagnosticLabel("consumer-unused-record")))
        }) ?? false
    }
}

/// Public-only configuration helpers for the external consumer proof.
public enum ConsumerSequentialSystem {
    /// Stable identity for this consumer-defined system implementation.
    public static var systemTypeID: SystemTypeID {
        type.id
    }

    /// Shared metadata for every consumer instance, with no persistence capability.
    public static let type = ScenarioSystemType("test.consumer-sequential")

    /// Creates the stable attachment identity for one named instance.
    ///
    /// - Parameter key: The caller-selected instance key.
    /// - Returns: A stable consumer-system attachment identity.
    public static func attachmentID(for key: AttachmentKey) -> AttachmentID {
        AttachmentID(systemTypeID: systemTypeID, key: key)
    }

    /// Creates the typed values-track identity for one named instance.
    ///
    /// - Parameter key: The caller-selected instance key.
    /// - Returns: The consumer system's sole sequential track identity.
    public static func trackID(for key: AttachmentKey) -> TrackID {
        TrackID(attachmentID: attachmentID(for: key), key: TrackKey(rawValue: "values"))
    }

    /// Creates one reusable instance for a named consumer attachment.
    ///
    /// - Parameters:
    ///   - key: The caller-selected instance key.
    ///   - values: Prepared baseline values; the type intentionally is not
    ///     `Codable`.
    ///   - mergeRecording: Optional consumer-owned merge of prepared tracks.
    /// - Returns: Typed immutable attachment, preparation, and lookup setup.
    /// - Throws: Public definition or preparation evidence.
    public static func instance(
        key: AttachmentKey,
        values: [ConsumerStableValue] = [],
        mergeRecording: RecordingMerge<ConsumerStableValue, Void>? = nil)
        throws -> ScenarioSystem<ConsumerSequentialDependency>
    {
        try ScenarioSystem(named: key.rawValue, definition: ConsumerSequentialDefinition(
            systemType: type, values: SystemTrack("values", values: prepared(values), mergeRecording: mergeRecording)))
    }

    private static func prepared(
        _ values: [ConsumerStableValue]) throws -> [PreparedValue<ConsumerStableValue>]
    {
        let definition = try ScenarioDefinition()
        let reporter = DiagnosticReporter(
            scenarioID: ScenarioID(rawValue: "test.consumer-preparation"),
            definition: definition)
        let preparation = ValuePreparation<ConsumerStableValue>()
        return try values.map { value in
            try preparation.prepare(
                capturing: { value },
                purpose: .replay,
                reporter: reporter)
        }
    }
}

struct ConsumerSequentialDefinition: SystemDefinition {
    let systemType: ScenarioSystemType
    let values: SystemTrack<ConsumerStableValue, Void>
    var tracks: [AnySystemTrack] {
        [values.erased]
    }

    func makeRecordState(in context: borrowing SystemStateContext) throws
        -> HeaderlessSequentialTrackLease<ConsumerStableValue>
    {
        try context.lease(for: values)
    }

    func makeReplayState(in context: borrowing SystemStateContext) throws
        -> HeaderlessSequentialTrackLease<ConsumerStableValue>
    {
        try context.lease(for: values)
    }

    func makeRecordDependency(using runtime: SystemRuntime<HeaderlessSequentialTrackLease<ConsumerStableValue>>)
        -> ConsumerSequentialDependency
    {
        ConsumerSequentialDependency(runtime: runtime, mode: .record)
    }

    func makeReplayDependency(using runtime: SystemRuntime<HeaderlessSequentialTrackLease<ConsumerStableValue>>)
        -> ConsumerSequentialDependency
    {
        ConsumerSequentialDependency(runtime: runtime, mode: .replay)
    }

    func makePassthroughDependency() -> ConsumerSequentialDependency {
        ConsumerSequentialDependency()
    }
}
