import DioramaCore
import Synchronization

private enum SourceOperationResult: Sendable {
    case value(UInt64)
    case failedTrackOperation
    case unavailable
}

private enum LiveRandomMode: Sendable {
    case record
    case passthrough
}

private protocol LiveRandomSource: Sendable {
    func nextRecording(
        lease: SequentialTrackLease<UInt64>,
        preparation: ValuePreparation<UInt64>) -> SourceOperationResult
    func nextPassthrough(lease: SequentialTrackLease<UInt64>) -> SourceOperationResult
    func close()
}

private final class TypedLiveRandomSource<Source: RandomNumberGenerator & Sendable>: LiveRandomSource, Sendable {
    private struct State: Sendable {
        var source: Source?
    }

    private let state: Mutex<State>

    init(_ source: Source) {
        state = Mutex(State(source: source))
    }

    func nextRecording(
        lease: SequentialTrackLease<UInt64>,
        preparation: ValuePreparation<UInt64>) -> SourceOperationResult
    {
        state.withLock { state in
            guard var source = state.source else { return .unavailable }
            var liveValue: UInt64?
            do {
                try lease.append(
                    capturing: {
                        let value = source.next()
                        state.source = source
                        liveValue = value
                        return value
                    },
                    preparation: preparation)
                guard let liveValue else {
                    preconditionFailure("Successful random recording must capture one value")
                }
                return .value(liveValue)
            } catch {
                if let liveValue {
                    return .value(liveValue)
                }
                return .failedTrackOperation
            }
        }
    }

    func nextPassthrough(lease: SequentialTrackLease<UInt64>) -> SourceOperationResult {
        state.withLock { state in
            guard !lease.isClosed, state.source != nil else { return .unavailable }
            return .value(state.source!.next())
        }
    }

    func close() {
        let detached = state.withLock { state in
            let source = state.source
            state.source = nil
            return source
        }
        withExtendedLifetime(detached) {}
    }
}

private final class LiveRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private static let closedOperation = DiagnosticLabel("random-operation-after-close")

    private let mode: LiveRandomMode
    private let lease: SequentialTrackLease<UInt64>
    private let preparation: ValuePreparation<UInt64>
    private let source: any LiveRandomSource

    init(
        mode: LiveRandomMode,
        lease: SequentialTrackLease<UInt64>,
        preparation: ValuePreparation<UInt64>,
        source: any LiveRandomSource)
    {
        self.mode = mode
        self.lease = lease
        self.preparation = preparation
        self.source = source
    }

    func next() -> UInt64 {
        let result: SourceOperationResult = switch mode {
        case .record:
            source.nextRecording(lease: lease, preparation: preparation)
        case .passthrough:
            source.nextPassthrough(lease: lease)
        }

        switch result {
        case let .value(value):
            return value
        case .failedTrackOperation:
            return 0
        case .unavailable:
            _ = lease.report(.system(Self.closedOperation))
            return 0
        }
    }
}

private final class ReplayRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private let lease: SequentialTrackLease<UInt64>

    init(lease: SequentialTrackLease<UInt64>) {
        self.lease = lease
    }

    func next() -> UInt64 {
        (try? lease.claimNext().value) ?? 0
    }
}

/// Setup helpers for Diorama's first-party random system.
public enum DioramaRandomSystem {
    static let type = ScenarioSystemType("diorama.random", persistence: DioramaRandomPersistence.registration)

    private static let valuesTrackKey = TrackKey(rawValue: "values")

    static func attachmentID(for key: AttachmentKey) -> AttachmentID {
        AttachmentID(systemTypeID: type.id, key: key)
    }

    static func trackID(for key: AttachmentKey) -> TrackID {
        TrackID(attachmentID: attachmentID(for: key), key: valuesTrackKey)
    }

    /// Creates one reusable random system.
    ///
    /// Recording forms a new `UInt64` sequence, replay consumes existing values,
    /// and passthrough ignores content. Select a mode on the returned system.
    ///
    /// - Parameters:
    ///   - key: The caller-selected random-domain key.
    ///   - allowsUnusedReplayRecords: Whether replay may leave random values unused.
    /// - Returns: Typed immutable setup using `SystemRandomNumberGenerator`.
    /// - Throws: Public scenario-definition evidence.
    public static func instance(
        for key: String,
        allowsUnusedReplayRecords: Bool = false) throws -> ScenarioSystem<any RandomNumberGenerator & Sendable>
    {
        try instance(for: key, allowsUnusedReplayRecords: allowsUnusedReplayRecords) { SystemRandomNumberGenerator() }
    }

    /// Creates one reusable random system with an injected source factory.
    ///
    /// The factory runs only during successful record or passthrough activation,
    /// once per execution; replay never initializes it. It must create
    /// independent state unless the consumer deliberately chooses to share a
    /// concurrency-safe source. For example:
    ///
    /// ```swift
    /// let random = try DioramaRandomSystem.instance(for: "random") {
    ///     KnownRandomNumberGenerator(values: [7, 11, 13])
    /// }
    /// let definition = try ScenarioDefinition(
    ///     attachments: [random.attachment])
    /// let execution = try ScenarioExecution.start(
    ///     definition: definition,
    ///     scenarioID: scenarioID, defaultMode: .record,
    ///     systems: [AnyScenarioSystem(random)])
    /// var generator = try execution.dependency(random)
    /// ```
    ///
    /// - Parameters:
    ///   - key: The caller-selected random-domain key.
    ///   - allowsUnusedReplayRecords: Whether replay may leave random values unused.
    ///   - sourceFactory: Creates the live source after all systems prepare.
    /// - Returns: Typed immutable attachment, preparation, and lookup setup.
    /// - Throws: Public scenario-definition evidence.
    public static func instance(
        for key: String,
        allowsUnusedReplayRecords: Bool = false,
        sourceFactory: @escaping @Sendable () -> some RandomNumberGenerator & Sendable)
        throws -> ScenarioSystem<any RandomNumberGenerator & Sendable>
    {
        let attachmentKey = AttachmentKey(rawValue: key)
        let trackID = trackID(for: attachmentKey)
        let attachment = try ScenarioAttachment(
            id: attachmentID(for: attachmentKey)).adding(
            SequentialTrack<UInt64>(id: trackID))
        return try ScenarioSystem(type: type, attachment: attachment,
                                  allowsUnusedReplayRecords: allowsUnusedReplayRecords)
        { context in
            let preparation = ValuePreparation<UInt64>()
            let lease = try context.lease(for: trackID, preparation: preparation)
            let mode: LiveRandomMode
            switch context.mode {
            case .replay:
                return PreparedSystem {
                    ActivatedSystem(
                        dependency: ReplayRandomNumberGenerator(lease: lease) as any RandomNumberGenerator & Sendable,
                        deactivate: {})
                }
            case .record:
                mode = .record
            case .passthrough:
                mode = .passthrough
            }
            return PreparedSystem {
                let source: any LiveRandomSource = TypedLiveRandomSource(sourceFactory())
                return ActivatedSystem(
                    dependency: LiveRandomNumberGenerator(
                        mode: mode,
                        lease: lease,
                        preparation: preparation,
                        source: source) as any RandomNumberGenerator & Sendable,
                    deactivate: { source.close() })
            }
        }
    }
}
