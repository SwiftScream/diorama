@testable import DioramaCore
@testable import DioramaLocation
import DioramaPersistence
import Dispatch
import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LocationCaptureTests {
    @Test
    func `reserved callback order survives slow preparation and interleaved access`() async throws {
        let fixture = try await LocationCaptureFixtures.start()
        try fixture.capture.state.withLock { state, operation in
            try state.startSession(timestampOrigin: LocationCaptureFixtures.timestampOrigin, operation: &operation)
        }
        fixture.clock.advance(.milliseconds(10))
        let first = try fixture.sessionObservation()
        let access = try fixture.accessObservation()
        fixture.clock.advance(.milliseconds(30))
        let second = try fixture.sessionObservation()
        #expect(try fixture.complete(second, .batch([fixture.location(-1000, at: second, east: 1)])))
        #expect(try fixture.complete(access, LocationCaptureFixtures.allowed))
        #expect(try fixture.complete(first, .batch([fixture.location(0, at: first), fixture.location(100, at: first)])))
        let result = await fixture.execution.finish()
        let recording = try fixture.recording(result)
        let session = try #require(recording.sessions.first)
        let firstLocation = try fixture.location(0, at: first)
        let nextLocation = try fixture.location(100, at: first)
        let lastLocation = try fixture.location(-1000, at: second, east: 1)
        #expect(firstLocation.latencyMilliseconds == 10)
        #expect(nextLocation.latencyMilliseconds == -90)
        #expect(lastLocation.latencyMilliseconds == 1040)
        #expect(session.events == [
            .batch(delayMilliseconds: 10, locations: [
                firstLocation, nextLocation,
            ]),
            .batch(delayMilliseconds: 30, locations: [
                lastLocation,
            ]),
        ])
        #expect(session.timestampOrigin?.value == LocationCaptureFixtures.timestampOrigin)
        #expect(recording.access.initialNotifications == [
            LocationAccessNotification(delayMilliseconds: 10, state: LocationCaptureFixtures.allowed),
        ])
        #expect(result.report.recordingHealth.isHealthy)
        #expect(await fixture.execution.finish().usage == result.usage)
    }

    @Test
    func `failure remains nonterminal and duplicate measurements retain their batch`() async throws {
        let fixture = try await LocationCaptureFixtures.start()
        try fixture.capture.state.withLock { state, operation in
            try state.startSession(timestampOrigin: LocationCaptureFixtures.timestampOrigin, operation: &operation)
        }
        fixture.clock.advance(.milliseconds(5))
        let error = try #require(NSErrorSnapshot.capture(NSError(domain: "location", code: 7)).snapshot)
        #expect(try fixture.complete(fixture.sessionObservation(), .failure(error)))
        fixture.clock.advance(.milliseconds(8))
        let recovery = try fixture.sessionObservation()
        #expect(try fixture.complete(recovery, .batch([
            fixture.location(0, at: recovery), fixture.location(0, at: recovery),
        ])))
        let recording = try await fixture.recording(fixture.execution.finish())
        let session = try #require(recording.sessions.first)
        #expect(session.events.count == 2)
        #expect(session.events[0] == .failure(delayMilliseconds: 5, error: error))
        guard case let .batch(delay, points) = session.events[1] else { Issue.record("Missing recovery"); return }
        #expect(delay == 8)
        #expect(points.map(\.latencyMilliseconds) == [13, 13])
    }

    @Test
    func `stop restart and repeated start preserve separate open sessions and fresh anchors`() async throws {
        let fixture = try await LocationCaptureFixtures.start()
        try fixture.capture.state.withLock { state, operation in
            try state.startSession(timestampOrigin: LocationCaptureFixtures.timestampOrigin, operation: &operation)
            try state.startSession(timestampOrigin: LocationCaptureFixtures.timestampOrigin, operation: &operation)
        }
        fixture.clock.advance(.milliseconds(10))
        let pending = try fixture.sessionObservation()
        try fixture.capture.state.withLock { state, operation in
            state.stopSession()
            state.stopSession()
            let ignored = try state.reserveSessionEvent(operation: &operation)
            #expect(ignored == nil)
        }
        fixture.clock.advance(.seconds(10))
        try fixture.capture.state.withLock { state, operation in
            try state.startSession(timestampOrigin: LocationCaptureFixtures.timestampOrigin, operation: &operation)
        }
        fixture.clock.advance(.milliseconds(3))
        #expect(try fixture.complete(fixture.sessionObservation(), .batch([])))
        #expect(try fixture.complete(pending, .batch([fixture.location(0, at: pending)])))
        try fixture.capture.state.withLock { state, operation in
            state.stopSession()
            try state.startSession(timestampOrigin: LocationCaptureFixtures.timestampOrigin, operation: &operation)
        }
        let recording = try await fixture.recording(fixture.execution.finish())
        #expect(recording.sessions.count == 3)
        #expect(recording.sessions[0].events.first?.delayMilliseconds == 10)
        #expect(recording.sessions[1].events == [.batch(delayMilliseconds: 3, locations: [])])
        #expect(recording.sessions[1].timestampOrigin == nil)
        #expect(recording.sessions[2].events.isEmpty)
        #expect(recording.sessions[2].timestampOrigin == nil)
    }

    @Test
    func `session start reference and prepared latencies survive late completion and persistence`() async throws {
        let fixture = try await LocationCaptureFixtures.start()
        fixture.clock.advance(.seconds(7))
        let origin = try #require(TimestampOrigin(
            date: LocationCaptureFixtures.timestampOrigin.date.addingTimeInterval(2.0006), offsetMinutes: 345))
        try fixture.capture.state.withLock { state, operation in
            try state.startSession(timestampOrigin: origin, operation: &operation)
        }
        fixture.clock.advance(.milliseconds(125))
        let observation = try fixture.sessionObservation()
        #expect(observation.timestampOrigin == origin)
        #expect(observation.deliveryMilliseconds == 125)
        let timestamps = [origin.date.addingTimeInterval(-1.0004), origin.date.addingTimeInterval(0.2504)]
        let locations = try timestamps.map { timestamp in
            let latency = try #require(observation.latency(for: timestamp))
            return try #require(LocationRecordedLocation(
                latencyMilliseconds: latency,
                coordinateOffset: .degrees(latitudeDegrees: 0.123456789, longitudeDegrees: 0),
                horizontalAccuracyMeters: 1.2345))
        }
        #expect(locations.map(\.latencyMilliseconds) == [1125, -125])
        #expect(locations[0].horizontalAccuracyMeters == 1.235)
        #expect(locations[0].coordinateOffset == .degrees(latitudeDegrees: 0.12345679, longitudeDegrees: 0))
        fixture.clock.advance(.seconds(5))
        #expect(try fixture.complete(observation, .batch(locations)))
        let result = await fixture.execution.finish()
        let recording = try fixture.recording(result)
        let session = try #require(recording.sessions.first)
        #expect(session.timestampOrigin == .observed(origin))
        #expect(session.events == [.batch(delayMilliseconds: 125, locations: locations)])
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([LocationTracks.type]))
        let persisted = try codec.decode(codec.encode(#require(result.definition)))
        let replay = try LocationTracks.recording(in: #require(persisted.attachments.first))
        #expect(replay == recording)
        for (location, timestamp) in zip(locations, timestamps) {
            let value = try replay.measurement(for: location, timestampOrigin: origin, deliveryMilliseconds: 125)
            #expect(value.timestamp == StableTimeCodec.roundedToMillisecond(timestamp))
        }
    }

    @Test
    func `latency preparation rejects invalid dates and subtraction overflow`() async throws {
        let fixture = try await LocationCaptureFixtures.start()
        try fixture.capture.state.withLock { state, operation in
            try state.startSession(timestampOrigin: LocationCaptureFixtures.timestampOrigin, operation: &operation)
        }
        let observation = try fixture.sessionObservation()
        for seconds in [Double.nan, .infinity, -.infinity, 253_402_250_000.001] {
            #expect(observation.latency(for: Date(timeIntervalSince1970: seconds)) == nil)
        }
        let extreme = LocationSessionObservation(
            owner: observation.owner, record: observation.record, index: observation.index,
            timestampOrigin: observation.timestampOrigin, deliveryMilliseconds: .max)
        #expect(extreme.latency(for: observation.timestampOrigin.date.addingTimeInterval(-1)) == nil)
        _ = await fixture.execution.finish()
    }

    @Test
    func `authorization barriers keep pending preceding notifications and reset only delivery anchors`() async throws {
        let fixture = try await LocationCaptureFixtures.start(hasLocations: false)
        fixture.clock.advance(.milliseconds(10))
        let initial = try fixture.accessObservation()
        fixture.clock.advance(.seconds(1))
        try fixture.capture.state.withLock { state, operation in
            try state.requestAuthorization(.whenInUse, operation: &operation)
        }
        fixture.clock.advance(.milliseconds(20))
        let following = try fixture.accessObservation()
        fixture.clock.advance(.milliseconds(30))
        let duplicate = try fixture.accessObservation()
        try fixture.capture.state.withLock { state, operation in
            try state.requestAuthorization(.always, operation: &operation)
            try state.beginAccess(operation: &operation)
        }
        #expect(try fixture.complete(duplicate, LocationCaptureFixtures.allowed))
        #expect(try fixture.complete(initial, LocationCaptureFixtures.initial))
        #expect(try fixture.complete(following, LocationCaptureFixtures.allowed))
        let result = await fixture.execution.finish()
        let recording = try fixture.recording(result)
        #expect(recording.access.initialNotifications == [
            LocationAccessNotification(delayMilliseconds: 10, state: LocationCaptureFixtures.initial),
        ])
        #expect(recording.access.requests == [
            LocationAccessRequestSegment(request: .whenInUse, notifications: [
                LocationAccessNotification(delayMilliseconds: 20, state: LocationCaptureFixtures.allowed),
                LocationAccessNotification(delayMilliseconds: 30, state: LocationCaptureFixtures.allowed),
            ]),
            LocationAccessRequestSegment(request: .always, notifications: []),
        ])
    }

    @Test
    func `pending conversion invalidates freeze and late completion cannot change the report`() async throws {
        let fixture = try await LocationCaptureFixtures.start()
        try fixture.capture.state.withLock { state, operation in
            try state.startSession(timestampOrigin: LocationCaptureFixtures.timestampOrigin, operation: &operation)
        }
        let pending = try fixture.sessionObservation()
        let result = await fixture.execution.finish()
        #expect(result.definition == nil)
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(throws: SequentialOperationFailure.self) {
            try fixture.complete(pending, .batch([]))
        }
        #expect(await fixture.execution.finish().report == result.report)
        #expect(fixture.capture.reporter.postFinishDiagnostics.count == 1)
        #expect(result.usage[0].tracks[0].activity == .record(recordedCount: 0, incompleteCount: 1))
    }

    @Test
    func `failed preparation invalidates candidate without retaining the captured value`() async throws {
        let fixture = try await LocationCaptureFixtures.start()
        try fixture.capture.state.withLock { state, operation in
            try state.startSession(timestampOrigin: LocationCaptureFixtures.timestampOrigin, operation: &operation)
        }
        _ = try fixture.sessionObservation()
        let policy = ValuePreparation<LocationCaptureEvent>(normalize: { _ in throw CaptureFailure.secret })
        #expect(throws: PreparationFailure.self) {
            try policy.prepare(capturing: { .batch([]) }, purpose: .recording, reporter: fixture.capture.reporter)
        }
        let result = await fixture.execution.finish()
        #expect(result.definition == nil)
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(!result.rendered().contains("secret"))
    }

    @Test(arguments: [false, true])
    func `prepared event transforms run once and duplicate completion is unhealthy`(duplicate: Bool) async throws {
        let fixture = try await LocationCaptureFixtures.start()
        try fixture.capture.state.withLock { state, operation in
            try state.startSession(timestampOrigin: LocationCaptureFixtures.timestampOrigin, operation: &operation)
        }
        let token = try fixture.sessionObservation()
        let counts = Mutex(0)
        let policy = ValuePreparation<LocationCaptureEvent>(normalize: { value in
            counts.withLock { $0 += 1 }
            return value
        })
        let prepared = try policy.prepare(capturing: { .batch([]) }, purpose: .recording,
                                          reporter: fixture.capture.reporter)
        try fixture.capture.state.withLock { state, operation in
            let completed = state.complete(token, with: prepared, operation: &operation)
            #expect(completed)
            if duplicate {
                let repeated = state.complete(token, with: prepared, operation: &operation)
                #expect(!repeated)
            }
        }
        let result = await fixture.execution.finish()
        #expect(counts.withLock { $0 } == 1)
        #expect((result.definition == nil) == duplicate)
        #expect(result.report.recordingHealth.isHealthy == !duplicate)
    }

    @Test
    func `concurrent reservations complete in reverse order without changing notification order`() async throws {
        let fixture = try await LocationCaptureFixtures.start(hasLocations: false)
        let tokens = try await withThrowingTaskGroup(of: LocationAccessObservation.self) { group in
            for _ in 0..<32 {
                group.addTask { try fixture.accessObservation() }
            }
            var tokens: [LocationAccessObservation] = []
            for try await token in group {
                tokens.append(token)
            }
            return tokens.sorted { $0.index > $1.index }
        }
        for token in tokens {
            let value = LocationRecordedAccessState(
                servicesEnabled: token.index.isMultiple(of: 2), permission: .denied, accuracy: .full)
            #expect(try fixture.complete(token, value))
        }
        let result = await fixture.execution.finish()
        let recording = try fixture.recording(result)
        #expect(recording.access.initialNotifications.map(\.state.servicesEnabled) ==
            (0..<32).map { $0.isMultiple(of: 2) })
        #expect(recording.access.initialNotifications.allSatisfy { $0.delayMilliseconds == 0 })
        #expect(result.report.recordingHealth.isHealthy)
    }

    @Test
    func `freeze racing blocked conversion detaches pending access and rejects late completion`() async throws {
        let fixture = try await LocationCaptureFixtures.start(hasLocations: false)
        let token = try fixture.accessObservation()
        let entered = AsyncStream<Void>.makeStream()
        let completed = AsyncStream<Bool>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue.global().async {
            let value = try? ValuePreparation<LocationRecordedAccessState>().prepare(capturing: {
                entered.continuation.finish()
                release.wait()
                return LocationCaptureFixtures.allowed
            }, purpose: .recording, reporter: fixture.capture.reporter)
            let accepted = value.flatMap { prepared in
                try? fixture.capture.state.withLock { state, operation in
                    state.complete(token, with: prepared, operation: &operation)
                }
            } ?? false
            completed.continuation.yield(accepted)
            completed.continuation.finish()
        }
        for await _ in entered.stream {}
        let result = await fixture.execution.finish()
        #expect(result.definition == nil)
        #expect(!result.report.recordingHealth.isHealthy)
        release.signal()
        for await accepted in completed.stream {
            #expect(!accepted)
        }
        #expect(await fixture.execution.finish().report == result.report)
        #expect(fixture.capture.reporter.postFinishDiagnostics.count == 1)
    }

    @Test
    func `millisecond delivery rounding uses absolute observations without cumulative drift`() async throws {
        let fixture = try await LocationCaptureFixtures.start(hasLocations: false)
        fixture.clock.advance(.microseconds(500))
        #expect(try fixture.complete(fixture.accessObservation(), LocationCaptureFixtures.allowed))
        fixture.clock.advance(.microseconds(600))
        #expect(try fixture.complete(fixture.accessObservation(), LocationCaptureFixtures.allowed))
        fixture.clock.advance(.microseconds(500))
        #expect(try fixture.complete(fixture.accessObservation(), LocationCaptureFixtures.allowed))
        let recording = try await fixture.recording(fixture.execution.finish())
        #expect(recording.access.initialNotifications.map(\.delayMilliseconds) == [1, 0, 1])
    }

    @Test
    func `escaped observation token retains no execution time service or mode state after finish`() async throws {
        var fixture: LocationCaptureFixtures? = try await LocationCaptureFixtures.start(hasLocations: false)
        weak let capture = fixture?.capture
        weak let time = fixture?.capture.time
        let token = try #require(fixture).accessObservation()
        #expect(try #require(fixture).complete(token, LocationCaptureFixtures.allowed))
        let result = try await #require(fixture).execution.finish()
        #expect(result.report.recordingHealth.isHealthy)
        fixture = nil
        #expect(capture == nil)
        #expect(time == nil)
        withExtendedLifetime(token) {}
    }

    @Test(arguments: [false, true])
    func `foreign tokens cannot complete the same record position in another execution`(session: Bool) async throws {
        let first = try await LocationCaptureFixtures.start(hasLocations: false)
        let second = try await LocationCaptureFixtures.start(hasLocations: false)
        if session {
            for fixture in [first, second] {
                try fixture.capture.state.withLock { state, operation in
                    try state.startSession(
                        timestampOrigin: LocationCaptureFixtures.timestampOrigin, operation: &operation)
                }
            }
            let token = try first.sessionObservation()
            let other = try second.sessionObservation()
            #expect(try !second.complete(token, .batch([])))
            #expect(try first.complete(token, .batch([])))
            #expect(try second.complete(other, .batch([])))
        } else {
            let token = try first.accessObservation()
            let other = try second.accessObservation()
            #expect(try !second.complete(token, LocationCaptureFixtures.allowed))
            #expect(try first.complete(token, LocationCaptureFixtures.allowed))
            #expect(try second.complete(other, LocationCaptureFixtures.allowed))
        }
        #expect(await first.execution.finish().report.recordingHealth.isHealthy)
        let rejected = await second.execution.finish()
        #expect(!rejected.report.recordingHealth.isHealthy)
        #expect(rejected.definition == nil)
    }

    @Test
    func `duplicate access completion invalidates its segment`() async throws {
        let fixture = try await LocationCaptureFixtures.start(hasLocations: false)
        let token = try fixture.accessObservation()
        #expect(try fixture.complete(token, LocationCaptureFixtures.allowed))
        #expect(try !fixture.complete(token, LocationCaptureFixtures.initial))
        let result = await fixture.execution.finish()
        #expect(result.definition == nil)
        #expect(result.usage[0].tracks[1].activity == .record(recordedCount: 0, incompleteCount: 1))
    }

    @Test
    func `failed time reservation invalidates candidate instead of producing a healthy open segment`() async throws {
        let fixture = try await LocationCaptureFixtures.start(hasLocations: false)
        fixture.clock.advance(.milliseconds(-1))
        #expect(throws: ExecutionTimeFailure.self) { try fixture.accessObservation() }
        fixture.clock.advance(.milliseconds(1))
        let result = await fixture.execution.finish()
        #expect(result.definition == nil)
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(result.usage[0].tracks[1].activity == .record(recordedCount: 0, incompleteCount: 1))
        #expect(result.report.diagnostics.contains {
            $0.diagnostic.issue == .conversionFailed && $0.diagnostic.recordingImpact == .invalidatesCandidate
        })
    }

    @Test
    func `request before access observation reserves an empty initial segment`() async throws {
        let fixture = try await LocationCaptureFixtures.start(hasLocations: false, observing: false)
        try fixture.capture.state.withLock { state, operation in
            let ignored = try state.reserveAccessNotification(operation: &operation)
            #expect(ignored == nil)
            try state.requestAuthorization(.always, operation: &operation)
        }
        let recording = try await fixture.recording(fixture.execution.finish())
        #expect(recording.access.initialNotifications.isEmpty)
        #expect(recording.access.requests == [LocationAccessRequestSegment(request: .always, notifications: [])])
    }
}

private enum CaptureFailure: Error { case secret }
