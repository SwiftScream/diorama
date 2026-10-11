import DioramaCore

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

private struct RandomRecordState<Source: RandomNumberGenerator & Sendable>: Sendable {
    var source: Source
    let values: HeaderlessSequentialTrackLease<UInt64>
}

private struct RecordingRandom<Source: RandomNumberGenerator & Sendable>: RandomNumberGenerator, Sendable {
    let runtime: SystemRuntime<RandomRecordState<Source>>

    func next() -> UInt64 {
        (try? runtime.withActiveState { state, operation in
            var result: UInt64 = 0
            // Reserve before the native read; preserve its return on late failure.
            _ = try? operation.record(on: state.values, capturing: {
                result = state.source.next()
                return result
            }, preparation: ValuePreparation<UInt64>())
            return result
        }) ?? 0
    }
}

private struct ReplayingRandom: RandomNumberGenerator, Sendable {
    let runtime: SystemRuntime<HeaderlessSequentialTrackLease<UInt64>>

    func next() -> UInt64 {
        (try? runtime.withActiveState { values, operation in
            try operation.consumeNext(on: values)
        }) ?? 0
    }
}

private struct RandomDefinition<Source: RandomNumberGenerator & Sendable>: SystemDefinition {
    let systemType = DioramaRandomSystem.type
    let values = SystemTrack<UInt64, Void>("values")
    let sourceFactory: @Sendable () -> Source

    var tracks: [AnySystemTrack] {
        [values.erased]
    }

    func makeRecordState(in context: borrowing SystemStateContext) throws -> RandomRecordState<Source> {
        let lease = try context.lease(for: values)
        return RandomRecordState(source: sourceFactory(), values: lease)
    }

    func makeReplayState(in context: borrowing SystemStateContext) throws -> HeaderlessSequentialTrackLease<UInt64> {
        try context.lease(for: values)
    }

    func makeRecordDependency(using runtime: SystemRuntime<RandomRecordState<Source>>)
        -> any RandomNumberGenerator & Sendable
    {
        RecordingRandom(runtime: runtime)
    }

    func makeReplayDependency(using runtime: SystemRuntime<HeaderlessSequentialTrackLease<UInt64>>)
        -> any RandomNumberGenerator & Sendable
    {
        ReplayingRandom(runtime: runtime)
    }

    func makePassthroughDependency() -> any RandomNumberGenerator & Sendable {
        sourceFactory()
    }
}
