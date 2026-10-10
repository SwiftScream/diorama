import DioramaCore
import Synchronization

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
    /// and passthrough returns the native source directly. Select a mode on the returned system.
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
    /// Recording copies share one serialized source, including after finish.
    /// Later reads diagnose closure and return live values without recording.
    /// Replay uses the track's zero fallback and never creates a live source.
    ///
    /// Passthrough returns that source directly. Value-generator copies advance
    /// independently; reference sources keep native sharing. Retained sources
    /// remain usable after finish without Diorama operation diagnostics.
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
        try ScenarioSystem(named: name, definition: RandomDefinition(sourceFactory: sourceFactory),
                           allowsUnclaimedReplayRecords: allowsUnclaimedReplayRecords)
    }
}

/// Native generator ownership follows the recording dependency, including
/// after recording closes. Its copies share one serialized source.
private final class RecordingRandomSource<Source: RandomNumberGenerator & Sendable>: Sendable {
    private let source: Mutex<Source>

    init(_ source: Source) {
        self.source = Mutex(source)
    }

    func next() -> UInt64 {
        source.withLock { $0.next() }
    }
}

private struct RecordingRandom<Source: RandomNumberGenerator & Sendable>: RandomNumberGenerator, Sendable {
    let execution: SystemExecution<HeaderlessSequentialTrackLease<UInt64>>
    let source: RecordingRandomSource<Source>

    func next() -> UInt64 {
        do {
            return try execution.withActiveState { values, operation in
                var result: UInt64?
                // Reserve before reading; a rejected recording must not lose or
                // repeat a native read that already happened.
                _ = try? operation.record(on: values, capturing: {
                    let native = source.next()
                    result = native
                    return native
                }, preparation: ValuePreparation<UInt64>())
                return result ?? source.next()
            }
        } catch {
            return source.next()
        }
    }
}

private struct ReplayingRandom: RandomNumberGenerator, Sendable {
    let values: HeaderlessSequentialTrackLease<UInt64>

    func next() -> UInt64 {
        (try? values.consumeNext()) ?? 0
    }
}

private struct RandomDefinition<Source: RandomNumberGenerator & Sendable>: SystemDefinition {
    let systemType = DioramaRandomSystem.type
    let values = TrackDefinition<UInt64, Void>("values", continuationPolicy: .fallback(0))
    let sourceFactory: @Sendable () -> Source

    var tracks: [AnyTrackDefinition] {
        [values.erased]
    }

    func makeRecordState(in context: borrowing SystemStateContext) throws -> HeaderlessSequentialTrackLease<UInt64> {
        try context.lease(for: values)
    }

    func makeReplayState(in context: borrowing SystemStateContext) throws -> HeaderlessSequentialTrackLease<UInt64> {
        try context.lease(for: values)
    }

    func makeRecordDependency(using execution: SystemExecution<HeaderlessSequentialTrackLease<UInt64>>)
        -> any RandomNumberGenerator & Sendable
    {
        RecordingRandom(execution: execution, source: RecordingRandomSource(sourceFactory()))
    }

    func makeReplayDependency(using execution: SystemExecution<HeaderlessSequentialTrackLease<UInt64>>)
        throws -> any RandomNumberGenerator & Sendable
    {
        try execution.withActiveState { values, _ in ReplayingRandom(values: values) }
    }

    func makePassthroughDependency() -> any RandomNumberGenerator & Sendable {
        sourceFactory()
    }
}
