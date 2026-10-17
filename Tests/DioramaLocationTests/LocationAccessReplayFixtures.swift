import CoreLocation
@testable import DioramaCore
@testable import DioramaLocation
import Synchronization
import Testing

@MainActor
final class LocationAccessReplayJournal {
    private let signal = AsyncStream<LocationAccessState>.makeStream()
    private(set) var states: [LocationAccessState] = []

    func connect(_ replay: LocationAccessReplay) {
        replay.observe { [weak replay] in
            guard let replay else {
                Issue.record("Access delivery outlived its replay service")
                return
            }
            self.append(replay.currentState)
        }
    }

    func append(_ state: LocationAccessState) {
        states.append(state)
        signal.continuation.yield(state)
    }

    func next() async throws -> LocationAccessState {
        var iterator = signal.stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }
}

private final class LocationAccessReplayControl: Sendable {
    let value = Mutex<SystemExecution<LocationAccessReplayState>?>(nil)
}

private enum LocationAccessReplayFixtureError: Error { case unexpectedLiveMode }

private struct LocationAccessReplayDefinition: SystemDefinition {
    let systemType = LocationTracks.type
    let sessions: TrackDefinition<LocationSession, LocationTracks.SessionHeader>
    let access: TrackDefinition<LocationTracks.AccessSegment, LocationRecordedAccessState>
    let control: LocationAccessReplayControl

    init(recording: LocationAccessRecording, control: LocationAccessReplayControl) throws {
        self.control = control
        sessions = try TrackDefinition(
            "sessions", header: ValuePreparation().admitPrepared(LocationTracks.SessionHeader(
                horizontal: nil, altitudeOrigin: nil, initial: nil)))
        let segments: [LocationTracks.AccessSegment] = [.initial(recording.initialNotifications)]
            + recording.requests.map(LocationTracks.AccessSegment.request)
        access = try TrackDefinition(
            "access", header: ValuePreparation().admitPrepared(recording.initialState),
            values: segments.map { try ValuePreparation().admitPrepared($0) })
    }

    var tracks: [AnyTrackDefinition] {
        [sessions.erased, access.erased]
    }

    func validate(in context: borrowing SystemValidationContext) throws {
        try context.validate(access) { access in
            let sessions = try context.track(sessions)
            let attachment = try ScenarioAttachment(id: context.attachmentID).adding(sessions).adding(access)
            _ = try LocationTracks.recording(in: attachment)
        }
    }

    var record: SystemModeDefinition<Void, LocationAccessReplay> {
        .init(makeDependency: { throw LocationAccessReplayFixtureError.unexpectedLiveMode })
    }

    var passthrough: SystemModeDefinition<Void, LocationAccessReplay> {
        record
    }

    var replay: SystemModeDefinition<LocationAccessReplayState, LocationAccessReplay> {
        .init(makeState: { context in
            try LocationAccessReplayState(
                access: context.lease(for: access), initialState: context.track(access).header)
        }, makeDependency: { @MainActor execution in
            control.value.withLock { $0 = execution }
            return try LocationAccessReplay(execution: execution)
        }, requestStop: { _, dependency in
            await dependency?.close()
        })
    }
}

struct LocationAccessReplayFixtures {
    let execution: ScenarioExecution
    let access: [LocationAccessReplay]
    let controls: [SystemExecution<LocationAccessReplayState>]
    let clock: LocationReplayClock

    static let initial = LocationRecordedAccessState(
        servicesEnabled: true, permission: .notDetermined, accuracy: .full)
    static let disabled = LocationRecordedAccessState(
        servicesEnabled: false, permission: .denied, accuracy: .reduced)
    static let whenInUse = LocationRecordedAccessState(
        servicesEnabled: true, permission: .whenInUse, accuracy: .reduced)
    static let always = LocationRecordedAccessState(
        servicesEnabled: true, permission: .always, accuracy: .full)

    @MainActor
    static func start(_ recordings: [LocationAccessRecording], clock: LocationReplayClock = .init(),
                      executionClock: ExecutionClock? = nil) async throws -> Self
    {
        var systems: [ScenarioSystem<LocationAccessReplay>] = []
        var controls: [SystemExecution<LocationAccessReplayState>] = []
        var slots: [LocationAccessReplayControl] = []
        for (index, recording) in recordings.enumerated() {
            let slot = LocationAccessReplayControl()
            slots.append(slot)
            try systems.append(ScenarioSystem(named: "gps-\(index)", definition: LocationAccessReplayDefinition(
                recording: recording, control: slot)))
        }
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: systems.map(\.attachment)),
            scenarioID: ScenarioID(rawValue: "location-access-replay"), defaultMode: .replay,
            systems: systems.map(AnyScenarioSystem.init), clock: executionClock ?? clock.source)
        let access = try systems.map { try execution.dependency($0.dependencyKey) }
        for slot in slots {
            try controls.append(#require(slot.value.withLock { $0 }))
        }
        return Self(execution: execution, access: access, controls: controls, clock: clock)
    }

    static func recording(initialState: LocationRecordedAccessState = initial,
                          notifications: [LocationAccessNotification] = [],
                          requests: [LocationAccessRequestSegment] = []) throws -> LocationAccessRecording
    {
        try LocationAccessRecording(
            initialState: initialState, initialNotifications: notifications, requests: requests)
    }
}
