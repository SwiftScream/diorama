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
    let wall: SystemTrack<OverridableValue<Date>, Int?>
    let sourceFactory: @Sendable () -> Source
    let timeZone: @Sendable () -> TimeZone

    init(sourceFactory: @escaping @Sendable () -> Source,
         timeZone: @escaping @Sendable () -> TimeZone = { .current }) throws
    {
        self.sourceFactory = sourceFactory
        self.timeZone = timeZone
        wall = try SystemTrack("wall", header: ValuePreparation<Int?>().admitPrepared(nil),
                               preparation: DioramaDateSystem.valuePreparation,
                               mergeRecording: DioramaDateSystem.mergeWallRecording)
    }

    var tracks: [AnySystemTrack] {
        [wall.erased]
    }

    func makeRecordState(in context: borrowing SystemStateContext) throws -> DateRecordState<Source> {
        let lease = try context.lease(for: wall)
        let recording = WallRecordingState(timeZone: timeZone())
        return DateRecordState(source: sourceFactory(), values: lease, recording: recording)
    }

    func makeReplayState(in context: borrowing SystemStateContext) throws -> DateReplayState {
        try DateReplayState(values: context.lease(for: wall))
    }

    func makeRecordDependency(using runtime: SystemRuntime<DateRecordState<Source>>) throws -> any DioramaDateSource {
        try runtime.withActiveState { state, operation in
            try operation.setHeader(on: state.values, capturing: { nil }, preparation: ValuePreparation<Int?>())
        }
        return RecordingDateSource(runtime: runtime, last: runtime.snapshot(\.lastReturned))
    }

    func makeReplayDependency(using runtime: SystemRuntime<DateReplayState>) -> any DioramaDateSource {
        ReplayingDateSource(runtime: runtime, last: runtime.snapshot(\.lastReturned))
    }

    func makePassthroughDependency() -> any DioramaDateSource {
        sourceFactory()
    }
}
