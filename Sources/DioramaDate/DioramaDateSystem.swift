import DioramaCore
import Foundation

/// Setup and persistence capability for first-party date attachments.
public enum DioramaDateSystem {
    /// The first-party date type and its versioned persistence capability.
    public static let type = ScenarioSystemType(
        "diorama.date", persistence: DioramaDatePersistence.registration)

    private static let wallTrackKey = TrackKey(rawValue: "wall")

    static let valuePreparation = ValuePreparation<OverridableValue<Date>>(validate: { value in
        guard StableTimeCodec.roundedToMillisecond(value.value) == value.value else {
            throw WallRecordingError.unrepresentableWallValue(position: 0)
        }
    })

    static func trackID(for key: AttachmentKey) -> TrackID {
        TrackID(
            attachmentID: AttachmentID(systemTypeID: type.id, key: key),
            key: wallTrackKey)
    }

    /// Builds an immutable date attachment from validated wall content.
    static func attachment(
        named name: String,
        recording: WallRecording = .empty) throws -> ScenarioAttachment
    {
        let key = AttachmentKey(rawValue: name)
        let trackID = trackID(for: key)
        return try ScenarioAttachment(id: trackID.attachmentID).adding(track(id: trackID, recording: recording))
    }

    /// Creates the same prepared track for authoring and finalization merge.
    static func track(
        id trackID: TrackID,
        recording: WallRecording) throws -> SequentialTrack<OverridableValue<Date>, Int?>
    {
        let preparation = valuePreparation
        let prepared = try recording.effectiveValues.enumerated().map { position, value in
            try preparation.admitPrepared(
                value,
                context: .record(RecordIdentity(trackID: trackID, sequence: UInt64(position))))
        }
        let header = try ValuePreparation<Int?>().admitPrepared(
            recording.offsetMinutes, context: .track(trackID))
        return SequentialTrack(id: trackID, header: header, values: prepared)
    }

    /// Reconstructs and validates the wall content of a date attachment.
    static func recording(in attachment: ScenarioAttachment) throws -> WallRecording {
        let trackID = trackID(for: attachment.id.key)
        guard attachment.id == trackID.attachmentID,
              attachment.trackIDs == [trackID],
              let track = try? attachment.track(
                  trackID, as: OverridableValue<Date>.self, header: Int?.self)
        else { throw WallRecordingError.invalidTrackLayout }
        return try WallRecording(
            offsetMinutes: track.header,
            values: track.records.map(\.value))
    }

    /// Creates one named date source backed by the platform wall source.
    ///
    /// Record captures the current encoding timezone at activation.
    /// Replay consumes the prepared wall track without activating a live source.
    public static func instance(
        named name: String,
        allowsUnclaimedReplayRecords: Bool = false) throws -> ScenarioSystem<any DioramaDateSource>
    {
        try instance(named: name,
                     allowsUnclaimedReplayRecords: allowsUnclaimedReplayRecords)
        {
            SystemWallDateSource()
        }
    }

    /// Creates one named date source with an injected live source factory.
    ///
    /// The factory runs only after successful preparation. Record mode
    /// serializes source reads with track operations. Passthrough returns the
    /// native source with its ordinary concurrency and lifetime requirements.
    /// After recording closes, the returned dependency keeps its live source:
    /// reads diagnose closure and return native dates without recording them.
    /// Recording selects the current timezone for origin display at activation;
    /// it never changes the absolute `Date` returned to the consumer.
    public static func instance(
        named name: String,
        allowsUnclaimedReplayRecords: Bool = false,
        sourceFactory: @escaping @Sendable () -> some DioramaDateSource)
        throws -> ScenarioSystem<any DioramaDateSource>
    {
        try ScenarioSystem(named: name, definition: DateDefinition(sourceFactory: sourceFactory),
                           allowsUnclaimedReplayRecords: allowsUnclaimedReplayRecords)
    }
}

struct DateDefinition<Source: DioramaDateSource>: SystemDefinition {
    let systemType = DioramaDateSystem.type
    let wall: TrackDefinition<OverridableValue<Date>, Int?>
    let sourceFactory: @Sendable () -> Source
    let timeZone: @Sendable () -> TimeZone

    init(sourceFactory: @escaping @Sendable () -> Source,
         timeZone: @escaping @Sendable () -> TimeZone = { .current }) throws
    {
        self.sourceFactory = sourceFactory
        self.timeZone = timeZone
        wall = try TrackDefinition(
            "wall", header: ValuePreparation<Int?>().admitPrepared(nil),
            preparation: DioramaDateSystem.valuePreparation,
            continuationPolicy: .replayLast(defaultValue: .observed(ReplayingDateSource.unixEpoch)),
            mergeRecording: DioramaDateSystem.mergeWallRecording)
    }

    var tracks: [AnyTrackDefinition] {
        [wall.erased]
    }

    func makeRecordState(in context: borrowing SystemStateContext) throws -> DateRecordState {
        let lease = try context.lease(for: wall)
        let recording = WallRecordingState(timeZone: timeZone())
        return DateRecordState(values: lease, recording: recording)
    }

    func makeReplayState(in context: borrowing SystemStateContext) throws
        -> SequentialTrackLease<OverridableValue<Date>, Int?>
    {
        try context.lease(for: wall)
    }

    func makeRecordDependency(using execution: SystemExecution<DateRecordState>) throws -> any DioramaDateSource {
        try execution.withActiveState { state, operation in
            try operation.setHeader(on: state.values, capturing: { nil }, preparation: ValuePreparation<Int?>())
        }
        return RecordingDateSource(execution: execution, source: sourceFactory())
    }

    func makeReplayDependency(using execution: SystemExecution<SequentialTrackLease<OverridableValue<Date>, Int?>>)
        throws -> any DioramaDateSource
    {
        try execution.withActiveState { values, _ in ReplayingDateSource(values: values) }
    }

    func makePassthroughDependency() -> any DioramaDateSource {
        sourceFactory()
    }
}
