import DioramaCore
import Synchronization

private enum SourceOperationResult: Sendable {
    case value(UInt64)
    case failedTrackOperation
    case unavailable
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

/// A reference-semantic random generator owned by one scenario attachment.
///
/// References to the same instance share one serialized live source and record
/// order. Separate attachments and separate executions receive fresh generator
/// state. B06 supports record and passthrough modes; replay is added by B07.
public final class DioramaRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private static let closedOperation = DiagnosticLabel("random-operation-after-close")

    private let lease: SequentialTrackLease<UInt64>
    private let preparation: ValuePreparation<UInt64>
    private let source: any LiveRandomSource

    fileprivate init(
        lease: SequentialTrackLease<UInt64>,
        preparation: ValuePreparation<UInt64>,
        source: any LiveRandomSource)
    {
        self.lease = lease
        self.preparation = preparation
        self.source = source
    }

    /// Returns the next live random value according to the attachment mode.
    ///
    /// Record mode serializes source access with stable admission and returns
    /// the live value even if a late recording failure makes the candidate
    /// unhealthy. Passthrough uses the source without touching track content.
    /// A call after finalization reports a lifecycle fact and returns zero
    /// without consulting the released source.
    ///
    /// - Returns: The next live value, or zero after diagnosed closure.
    public func next() -> UInt64 {
        let result = switch lease.mode {
        case .record:
            source.nextRecording(lease: lease, preparation: preparation)
        case .passthrough:
            source.nextPassthrough(lease: lease)
        case .replay:
            preconditionFailure("Replay activation is unavailable before B07")
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

/// Setup helpers for Diorama's first-party random system.
public enum DioramaRandomSystem {
    /// The stable identity of the first-party random system.
    public static let systemTypeID = SystemTypeID(rawValue: "diorama.random")

    private static let valuesTrackKey = TrackKey(rawValue: "values")
    private static let replayUnavailable = DiagnosticLabel("random-replay-unavailable-before-b07")

    /// Creates the stable identity for one named random attachment.
    ///
    /// - Parameter key: The caller-selected random-domain key.
    /// - Returns: A distinct identity using the stable random system type.
    public static func attachmentID(for key: AttachmentKey) -> AttachmentID {
        AttachmentID(systemTypeID: systemTypeID, key: key)
    }

    /// Creates the raw-values track identity for one named random attachment.
    ///
    /// - Parameter key: The caller-selected random-domain key.
    /// - Returns: The attachment's sole sequential track identity.
    public static func trackID(for key: AttachmentKey) -> TrackID {
        TrackID(attachmentID: attachmentID(for: key), key: valuesTrackKey)
    }

    /// Creates an empty in-memory declaration for one random attachment.
    ///
    /// Recording forms a new `UInt64` sequence and passthrough ignores content.
    /// B07 adds replay content consumption; persistence arrives in phase C.
    ///
    /// - Parameters:
    ///   - key: The caller-selected random-domain key.
    ///   - modeOverride: An optional mode for this whole attachment.
    /// - Returns: A random attachment containing one typed values track.
    /// - Throws: Public scenario-definition evidence.
    public static func attachment(
        for key: AttachmentKey,
        modeOverride: ScenarioMode? = nil) throws -> ScenarioAttachment
    {
        try ScenarioAttachment(
            id: attachmentID(for: key),
            modeOverride: modeOverride).adding(
            SequentialTrack<UInt64>(id: trackID(for: key)))
    }

    /// Registers a random attachment using a fresh system source per execution.
    ///
    /// - Parameter key: The caller-selected random-domain key.
    /// - Returns: A registration defaulting to `SystemRandomNumberGenerator`.
    public static func registration(for key: AttachmentKey) -> ScenarioSystem {
        registration(for: key) { SystemRandomNumberGenerator() }
    }

    /// Registers a random attachment with an injected source factory.
    ///
    /// The factory runs only during successful record or passthrough activation,
    /// once per execution. It must create independent state unless the consumer
    /// deliberately chooses to share a concurrency-safe source. For example:
    ///
    /// ```swift
    /// let registration = DioramaRandomSystem.registration(for: randomKey) {
    ///     KnownRandomNumberGenerator(values: [7, 11, 13])
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - key: The caller-selected random-domain key.
    ///   - sourceFactory: Creates the live source after all systems prepare.
    /// - Returns: A public core registration for this random attachment.
    public static func registration(
        for key: AttachmentKey,
        sourceFactory: @escaping @Sendable () -> some RandomNumberGenerator & Sendable) -> ScenarioSystem

    {
        let attachmentID = attachmentID(for: key)
        let trackID = trackID(for: key)
        return ScenarioSystem(attachmentID: attachmentID) { context in
            guard context.mode != .replay else {
                context.reporter.record(Diagnostic(
                    issue: .system(replayUnavailable),
                    context: .attachment(attachmentID)))
                throw ReplayUnavailable()
            }
            let preparation = ValuePreparation<UInt64>()
            let lease = try context.lease(for: trackID, preparation: preparation)
            return PreparedSystem {
                let source: any LiveRandomSource = TypedLiveRandomSource(sourceFactory())
                return SystemActivation(
                    dependency: DioramaRandomNumberGenerator(
                        lease: lease,
                        preparation: preparation,
                        source: source),
                    deactivate: { source.close() })
            }
        }
    }

    private struct ReplayUnavailable: Error {}
}
