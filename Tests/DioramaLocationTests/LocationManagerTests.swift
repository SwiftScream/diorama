import CoreLocation
@testable import DioramaCore
@testable import DioramaLocation
import Foundation
import Testing

private struct ManagerDefinition: SystemDefinition {
    let systemType = LocationTracks.type
    let sessions: TrackDefinition<LocationSession, LocationTracks.SessionHeader>
    let access: TrackDefinition<LocationTracks.AccessSegment, LocationRecordedAccessState>
    let fidelity: LocationFidelityOptions

    init(_ recording: LocationRecording, fidelity: LocationFidelityOptions) throws {
        self.fidelity = fidelity
        let attachment = try LocationTracks.attachment(named: "gps", recording: recording)
        let sessionTrack = try #require(try attachment.track(
            attachment.trackIDs[0], as: LocationSession.self, header: LocationTracks.SessionHeader.self))
        let accessTrack = try #require(try attachment.track(
            attachment.trackIDs[1], as: LocationTracks.AccessSegment.self, header: LocationRecordedAccessState.self))
        sessions = try TrackDefinition("sessions", header: ValuePreparation().admitPrepared(sessionTrack.header),
                                       values: sessionTrack.records.map {
                                           try ValuePreparation().admitPrepared($0.value)
                                       })
        access = try TrackDefinition("access", header: ValuePreparation().admitPrepared(accessTrack.header),
                                     values: accessTrack.records.map { try ValuePreparation().admitPrepared($0.value) })
    }

    var tracks: [AnyTrackDefinition] {
        [sessions.erased, access.erased]
    }

    var record: SystemModeDefinition<Void, DioramaLocationManager> {
        .init(makeDependency: { throw LocationRecordingError.invalidTrackLayout })
    }

    var passthrough: SystemModeDefinition<Void, DioramaLocationManager> {
        record
    }

    var replay: SystemModeDefinition<LocationReplayState, DioramaLocationManager> {
        .init(makeState: { context in
            try LocationReplayState(sessions: context.lease(for: sessions), access: context.lease(for: access))
        }, makeDependency: { @MainActor execution in
            try DioramaLocationManager(execution: execution, fidelity: fidelity)
        }, requestStop: { _, manager in await manager?.close() })
    }
}

@MainActor
private final class ManagerJournal: DioramaLocationManagerDelegate {
    let signal = AsyncStream<String>.makeStream()
    var batches: [[CLLocation]] = []
    var errors: [NSError] = []
    var authorizations = 0

    func locationManager(_ manager: DioramaLocationManager, didUpdateLocations locations: [CLLocation]) {
        #expect(manager.location === locations.last)
        batches.append(locations)
        signal.continuation.yield("batch")
    }

    func locationManager(_: DioramaLocationManager, didFailWithError error: Error) {
        errors.append(error as NSError)
        signal.continuation.yield("error")
    }

    func locationManagerDidChangeAuthorization(_ manager: DioramaLocationManager) {
        #expect(manager.locationServicesEnabled == false)
        #expect(manager.authorizationStatus == .denied)
        #expect(manager.accuracyAuthorization == .reducedAccuracy)
        authorizations += 1
        signal.continuation.yield("access")
    }

    func next() async throws -> String {
        var iterator = signal.stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct LocationManagerTests {
    private func start(_ recording: LocationRecording, fidelity: LocationFidelityOptions = .init(),
                       clock: ExecutionClock = .continuous()) async throws
        -> (ScenarioExecution, DioramaLocationManager)
    {
        let system = try ScenarioSystem(named: "gps", definition: ManagerDefinition(recording, fidelity: fidelity))
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]), scenarioID: .init(rawValue: "manager"),
            defaultMode: .replay, systems: [AnyScenarioSystem(system)], clock: clock)
        return try (execution, execution.dependency(system))
    }

    @Test(arguments: [false, true], [false, true])
    func `native batches and errors reach latest weak delegate after state installs`(
        floor: Bool, ellipsoidal: Bool) async throws
    {
        let point = try LocationUpdateReplayFixtures.point()
        let error = try #require(NSErrorSnapshot(domain: "location.test", code: 17))
        let recording = try LocationUpdateReplayFixtures.recording([
            [
                .batch(delayMilliseconds: 0, locations: [point]),
                .failure(delayMilliseconds: 0, error: error),
            ],
        ])
        let (execution, manager) = try await start(recording, fidelity: .init(
            preserveFloor: floor, preserveEllipsoidalAltitude: ellipsoidal))
        let delegate = ManagerJournal()
        manager.delegate = delegate
        manager.startUpdatingLocation()
        #expect(try await delegate.next() == "batch")
        #expect(try await delegate.next() == "error")
        #expect(delegate.batches.count == 1)
        #expect(delegate.errors.first?.domain == "location.test")
        #expect(delegate.errors.first?.code == 17)
        if floor {
            #expect(manager.location?.floor?.level == 3)
        }
        let last = manager.location
        _ = await execution.finish()
        #expect(manager.location === last)
        let replacement = ManagerJournal()
        manager.delegate = replacement
        manager.startUpdatingLocation()
        manager.requestAlwaysAuthorization()
        manager.requestWhenInUseAuthorization()
        manager.stopUpdatingLocation()
        #expect(replacement.batches.isEmpty)
        #expect(replacement.authorizations == 0)
        #expect(replacement.errors.isEmpty)
    }

    @Test(arguments: [false, true])
    func `replacement routes pending batches and finish suppresses pending delivery`(finishFirst: Bool) async throws {
        let point = try LocationUpdateReplayFixtures.point()
        let recording = try LocationUpdateReplayFixtures.recording([
            [
                .batch(delayMilliseconds: 1000, locations: [point]),
            ],
        ])
        let clock = LocationReplayClock()
        let (execution, manager) = try await start(recording, clock: clock.source)
        let original = ManagerJournal()
        let replacement = ManagerJournal()
        manager.delegate = original
        manager.startUpdatingLocation()
        try await clock.waitForDeadline(.seconds(1))
        manager.delegate = replacement
        if finishFirst {
            _ = await execution.finish()
            clock.advance(to: .seconds(1))
            #expect(replacement.batches.isEmpty)
            #expect(manager.location == nil)
        } else {
            clock.advance(to: .seconds(1))
            #expect(try await replacement.next() == "batch")
            _ = await execution.finish()
        }
        #expect(original.batches.isEmpty)
    }

    @Test
    func `delegate is weak and configuration freezes at finish`() async throws {
        let recording = try LocationUpdateReplayFixtures.recording([])
        let (execution, manager) = try await start(recording)
        var delegate: ManagerJournal? = ManagerJournal()
        weak let weakDelegate = delegate
        manager.delegate = delegate
        delegate = nil
        #expect(weakDelegate == nil)
        #expect(manager.delegate == nil)
        manager.desiredAccuracy = 12
        manager.distanceFilter = 34
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        _ = manager.location
        _ = manager.authorizationStatus
        let result = await execution.finish()
        manager.desiredAccuracy = 99
        manager.distanceFilter = 99
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
        #expect(manager.desiredAccuracy == 12)
        #expect(manager.distanceFilter == 34)
        #expect(manager.activityType == .fitness)
        #expect(manager.pausesLocationUpdatesAutomatically == false)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test
    func `registration starts access observation and callbacks see complete native state`() async throws {
        let access = try LocationAccessRecording(
            initialState: LocationAccessReplayFixtures.initial,
            initialNotifications: [.init(delayMilliseconds: 0, state: LocationAccessReplayFixtures.disabled)],
            requests: [.init(request: .always, notifications: [])])
        let recording = try LocationRecording(coordinateSpace: nil, sessions: [], access: access)
        let (execution, manager) = try await start(recording)
        #expect(manager.locationServicesEnabled)
        #expect(manager.authorizationStatus == .notDetermined)
        let delegate = ManagerJournal()
        manager.delegate = delegate
        #expect(try await delegate.next() == "access")
        manager.requestAlwaysAuthorization()
        let result = await execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(manager.locationServicesEnabled == false)
        #expect(delegate.authorizations == 1)
    }
}
