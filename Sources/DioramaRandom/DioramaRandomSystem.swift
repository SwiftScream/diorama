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

private final class LiveRandomNumberGenerator<Source: RandomNumberGenerator & Sendable>:
    RandomNumberGenerator, Sendable
{
    private struct State: Sendable {
        var source: Source?
    }

    private let mode: LiveRandomMode
    private let lease: HeaderlessSequentialTrackLease<UInt64>
    private let preparation: ValuePreparation<UInt64>
    private let state: Mutex<State>

    init(
        mode: LiveRandomMode,
        lease: HeaderlessSequentialTrackLease<UInt64>,
        preparation: ValuePreparation<UInt64>,
        source: Source)
    {
        self.mode = mode
        self.lease = lease
        self.preparation = preparation
        state = Mutex(State(source: source))
    }

    func next() -> UInt64 {
        let result: SourceOperationResult = switch mode {
        case .record:
            nextRecording()
        case .passthrough:
            nextPassthrough()
        }

        switch result {
        case let .value(value):
            return value
        case .failedTrackOperation:
            return 0
        case .unavailable:
            _ = lease.report(.system(DiagnosticLabel("random-operation-after-close")))
            return 0
        }
    }

    private func nextRecording() -> SourceOperationResult {
        state.withLock { state in
            guard var source = state.source else { return .unavailable }
            var liveValue: UInt64?
            do {
                try lease.record(
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

    private func nextPassthrough() -> SourceOperationResult {
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

private final class ReplayRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private let lease: HeaderlessSequentialTrackLease<UInt64>

    init(lease: HeaderlessSequentialTrackLease<UInt64>) {
        self.lease = lease
    }

    func next() -> UInt64 {
        (try? lease.consumeNext().value) ?? 0
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
    ///   - name: The caller-selected random-domain name.
    ///   - allowsUnclaimedReplayRecords: Whether replay may leave random values unclaimed.
    /// - Returns: Typed immutable setup using `SystemRandomNumberGenerator`.
    /// - Throws: Public scenario-definition evidence.
    public static func instance(
        named name: String,
        allowsUnclaimedReplayRecords: Bool = false) throws -> ScenarioSystem<any RandomNumberGenerator & Sendable>
    {
        try instance(named: name, allowsUnclaimedReplayRecords: allowsUnclaimedReplayRecords) {
            SystemRandomNumberGenerator()
        }
    }

    /// Creates one reusable random system with an injected source factory.
    ///
    /// The factory runs only during successful record or passthrough activation,
    /// once per execution; replay never initializes it. It must create
    /// independent state unless the consumer deliberately chooses to share a
    /// concurrency-safe source. For example:
    ///
    /// ```swift
    /// let random = try DioramaRandomSystem.instance(named: "random") {
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
    ///   - name: The caller-selected random-domain name.
    ///   - allowsUnclaimedReplayRecords: Whether replay may leave random values unclaimed.
    ///   - sourceFactory: Creates the live source after all systems prepare.
    /// - Returns: Typed immutable attachment, preparation, and lookup setup.
    /// - Throws: Public scenario-definition evidence.
    public static func instance(
        named name: String,
        allowsUnclaimedReplayRecords: Bool = false,
        sourceFactory: @escaping @Sendable () -> some RandomNumberGenerator & Sendable)
        throws -> ScenarioSystem<any RandomNumberGenerator & Sendable>
    {
        let attachmentKey = AttachmentKey(rawValue: name)
        let trackID = trackID(for: attachmentKey)
        let attachment = try ScenarioAttachment(
            id: attachmentID(for: attachmentKey)).adding(
            HeaderlessSequentialTrack<UInt64>(id: trackID))
        return try ScenarioSystem(type: type, attachment: attachment,
                                  allowsUnclaimedReplayRecords: allowsUnclaimedReplayRecords)
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
                let generator = LiveRandomNumberGenerator(
                    mode: mode, lease: lease, preparation: preparation, source: sourceFactory())
                return ActivatedSystem(
                    dependency: generator as any RandomNumberGenerator & Sendable,
                    deactivate: { generator.close() })
            }
        }
    }
}
