import CoreLocation
@testable import DioramaCore
@testable import DioramaLocation
import Foundation
import Synchronization
import Testing

/// Test-only time and observation streams; no async consumer interface is added.
final class LocationReplayClock: Sendable {
    private struct Wait {
        let deadline: Duration
        let signal: AsyncStream<Void>.Continuation
    }

    private struct State {
        var now: Duration = .zero
        var nextID = 0
        var waits: [Int: Wait] = [:]
    }

    private let origin = ContinuousClock.now
    private let state = Mutex(State())
    private let registrations = AsyncStream<Duration>.makeStream()

    var source: ExecutionClock {
        ExecutionClock(now: { self.origin.advanced(by: self.state.withLock { $0.now }) }, sleep: { deadline, _ in
            let signal = AsyncStream<Void>.makeStream()
            let relative = self.origin.duration(to: deadline)
            let id = self.state.withLock { state in
                let id = state.nextID
                state.nextID += 1
                state.waits[id] = Wait(deadline: relative, signal: signal.continuation)
                if relative <= state.now {
                    signal.continuation.finish()
                }
                return id
            }
            self.registrations.continuation.yield(relative)
            for await _ in signal.stream {}
            self.state.withLock { $0.waits[id] = nil }
            try Task.checkCancellation()
        })
    }

    func advance(to now: Duration) {
        let signals = state.withLock { state in
            state.now = now
            return state.waits.values.filter { $0.deadline <= now }.map(\.signal)
        }
        for signal in signals {
            signal.finish()
        }
    }

    func waitForDeadline(_ expected: Duration) async throws {
        var iterator = registrations.stream.makeAsyncIterator()
        while let deadline = await iterator.next() {
            if deadline == expected {
                return
            }
        }
        Issue.record("Clock registration stream ended before the expected deadline")
    }
}

@MainActor
final class LocationReplayJournal {
    private let signal = AsyncStream<String>.makeStream()
    private(set) var order: [String] = []
    private(set) var batches: [[CLLocation]] = []
    private(set) var errors: [NSError] = []

    func connect(_ replay: LocationUpdateReplay) {
        replay.setDelivery(locations: { [weak replay] values in
            if let last = values.last {
                #expect(replay?.currentLocation === last)
            }
            self.batches.append(values)
            self.append("batch")
        }, failure: { error in
            self.errors.append(error as NSError)
            self.append("failure")
        })
    }

    func append(_ value: String) {
        order.append(value)
        signal.continuation.yield(value)
    }

    func next() async throws -> String {
        var iterator = signal.stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }
}

private final class LocationReplayControl: Sendable {
    let value = Mutex<SystemExecution<LocationUpdateReplayState>?>(nil)
}

private enum LocationReplayFixtureError: Error { case unexpectedMode }

private struct LocationReplayDefinition: SystemDefinition {
    let systemType = LocationTracks.type
    let sessions: TrackDefinition<LocationSession, LocationTracks.SessionHeader>
    let access: TrackDefinition<LocationTracks.AccessSegment, LocationRecordedAccessState>
    let fidelity: LocationFidelityOptions
    let control: LocationReplayControl

    init(recording: LocationRecording, fidelity: LocationFidelityOptions,
         control: LocationReplayControl) throws
    {
        self.fidelity = fidelity
        self.control = control
        let attachment = try LocationTracks.attachment(named: "layout", recording: recording)
        let sessionTrack = try #require(try attachment.track(
            TrackID(attachmentID: attachment.id, key: TrackKey(rawValue: "sessions")),
            as: LocationSession.self, header: LocationTracks.SessionHeader.self))
        let accessTrack = try #require(try attachment.track(
            TrackID(attachmentID: attachment.id, key: TrackKey(rawValue: "access")),
            as: LocationTracks.AccessSegment.self, header: LocationRecordedAccessState.self))
        sessions = try TrackDefinition(
            "sessions", header: ValuePreparation().admitPrepared(sessionTrack.header),
            values: sessionTrack.records.map { try ValuePreparation().admitPrepared($0.value) })
        access = try TrackDefinition(
            "access", header: ValuePreparation().admitPrepared(accessTrack.header),
            values: accessTrack.records.map { try ValuePreparation().admitPrepared($0.value) })
    }

    var tracks: [AnyTrackDefinition] {
        [sessions.erased, access.erased]
    }

    func validate(in context: borrowing SystemValidationContext) throws {
        try context.validate(sessions) { sessions in
            let access = try context.track(access)
            let attachment = try ScenarioAttachment(id: context.attachmentID).adding(sessions).adding(access)
            _ = try LocationTracks.recording(in: attachment)
        }
    }

    var record: SystemModeDefinition<Void, LocationUpdateReplay> {
        .init(makeDependency: { throw LocationReplayFixtureError.unexpectedMode })
    }

    var passthrough: SystemModeDefinition<Void, LocationUpdateReplay> {
        record
    }

    var replay: SystemModeDefinition<LocationUpdateReplayState, LocationUpdateReplay> {
        .init(makeState: { context in
            try LocationUpdateReplayState(
                sessions: context.lease(for: sessions), header: context.track(sessions).header)
        }, makeDependency: { @MainActor execution in
            control.value.withLock { $0 = execution }
            return try LocationUpdateReplay(execution: execution, fidelity: fidelity)
        }, requestStop: { _, dependency in
            await dependency?.close()
        })
    }
}

struct LocationUpdateReplayFixtures {
    let execution: ScenarioExecution
    let updates: [LocationUpdateReplay]
    let controls: [SystemExecution<LocationUpdateReplayState>]
    let clock: LocationReplayClock

    static let timestampOrigin = TimestampOrigin(date: Date(timeIntervalSince1970: 1_700_000_000), offsetMinutes: 0)!

    @MainActor
    static func start(_ recordings: [LocationRecording], fidelity: LocationFidelityOptions = .init(),
                      clock: LocationReplayClock = .init(), executionClock: ExecutionClock? = nil) async throws -> Self
    {
        var systems: [ScenarioSystem<LocationUpdateReplay>] = []
        var controls: [SystemExecution<LocationUpdateReplayState>] = []
        var slots: [LocationReplayControl] = []
        for (index, recording) in recordings.enumerated() {
            let slot = LocationReplayControl()
            slots.append(slot)
            try systems.append(ScenarioSystem(named: "gps-\(index)", definition: LocationReplayDefinition(
                recording: recording, fidelity: fidelity, control: slot)))
        }
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: systems.map(\.attachment)),
            scenarioID: ScenarioID(rawValue: "location-replay"), defaultMode: .replay,
            systems: systems.map(AnyScenarioSystem.init), clock: executionClock ?? clock.source)
        let updates = try systems.map { try execution.dependency($0.dependencyKey) }
        for slot in slots {
            try controls.append(#require(slot.value.withLock { $0 }))
        }
        return Self(execution: execution, updates: updates, controls: controls, clock: clock)
    }

    static func point(latency: Int64 = 0, latitude: Double = 0) throws -> LocationRecordedLocation {
        try #require(LocationRecordedLocation(
            latencyMilliseconds: latency, coordinateOffset: .degrees(latitudeDegrees: latitude, longitudeDegrees: 0),
            horizontalAccuracyMeters: 1, floor: LocationRecordedFloor(level: 3)))
    }

    static func recording(_ sessions: [[LocationSessionEvent]], initial: LocationRecordedLocation? = nil)
        throws -> LocationRecording
    {
        let hasLocations = initial != nil || sessions.joined().contains {
            if case let .batch(_, points) = $0 {
                return !points.isEmpty
            }
            return false
        }
        return try LocationRecording(
            horizontal: hasLocations ? LocationHorizontalSpace(format: .degrees, origin: .observed(
                #require(LocationCoordinate(latitudeDegrees: 10, longitudeDegrees: 20)))) : nil,
            altitudeOrigin: nil,
            initial: initial.map { try LocationInitialSnapshot(timestampOrigin: timestampOrigin, location: $0) },
            sessions: sessions.map { events in
                let hasLocations = events.contains {
                    if case let .batch(_, points) = $0 {
                        return !points.isEmpty
                    }
                    return false
                }
                return try LocationSession(
                    timestampOrigin: hasLocations ? .observed(timestampOrigin) : nil, events: events)
            },
            access: LocationAccessRecording(
                initialState: LocationRecordedAccessState(
                    servicesEnabled: true, permission: .notDetermined, accuracy: .full),
                initialNotifications: [], requests: []))
    }
}
