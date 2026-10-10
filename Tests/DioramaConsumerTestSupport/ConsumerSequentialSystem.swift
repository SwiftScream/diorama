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
        case let .managed(lease, _): lease.mode
        case .passthrough: .passthrough
        }
    }

    /// Whether the execution has closed this dependency's track lease.
    public var isClosed: Bool {
        switch behavior {
        case let .managed(lease, _): lease.isClosed
        case .passthrough: false
        }
    }

    private enum Behavior: Sendable {
        case managed(HeaderlessSequentialTrackLease<ConsumerStableValue>, ValuePreparation<ConsumerStableValue>)
        case passthrough
    }

    private let behavior: Behavior

    init() {
        behavior = .passthrough
    }

    init(
        lease: HeaderlessSequentialTrackLease<ConsumerStableValue>,
        preparation: ValuePreparation<ConsumerStableValue>)
    {
        behavior = .managed(lease, preparation)
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
        guard case let .managed(lease, preparation) = behavior else { return liveValue() }
        guard !lease.isClosed else {
            _ = lease.report(.system(DiagnosticLabel("consumer-operation-after-close")))
            throw ConsumerSystemFailure.closed
        }

        switch lease.mode {
        case .record:
            var observation: ConsumerStableValue?
            try lease.record(
                capturing: {
                    let value = liveValue()
                    observation = value
                    return value
                },
                preparation: preparation)
            guard let observation else {
                preconditionFailure("Successful record append must capture one value")
            }
            return observation
        case .replay:
            return try lease.consumeNext()
        case .passthrough:
            return liveValue()
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
        guard case let .managed(lease, _) = behavior else { return false }
        return lease.report(.system(DiagnosticLabel("consumer-unused-record")))
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
        let track = try SequentialTrack(
            id: trackID(for: key),
            values: prepared(values))
        let attachment = try ScenarioAttachment(
            id: attachmentID(for: key)).adding(track)
        let trackID = trackID(for: key)
        return try ScenarioSystem(type: type, attachment: attachment) { context in
            if context.mode == .passthrough {
                return PreparedSystem {
                    ActivatedSystem(dependency: ConsumerSequentialDependency(), deactivate: {})
                }
            }
            let preparation = ValuePreparation<ConsumerStableValue>()
            let lease = try context.lease(for: trackID, preparation: preparation, mergeRecording: mergeRecording)
            return PreparedSystem {
                ActivatedSystem(
                    dependency: ConsumerSequentialDependency(
                        lease: lease,
                        preparation: preparation),
                    deactivate: {})
            }
        }
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
