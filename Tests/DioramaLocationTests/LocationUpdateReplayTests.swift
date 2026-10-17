import CoreLocation
@testable import DioramaCore
@testable import DioramaLocation
import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LocationUpdateReplayTests {
    private typealias Fixtures = LocationUpdateReplayFixtures

    @Test @MainActor
    func `late replay preserves batch order timestamps failures and cached state`() async throws {
        let first = try Fixtures.point(latency: 500, latitude: 1)
        let duplicate = try Fixtures.point(latency: 500, latitude: 2)
        let future = try Fixtures.point(latency: -100, latitude: 3)
        let failure = try #require(NSErrorSnapshot(
            domain: "fixture.location", code: 7, userInfo: ["reason": .string("retry")]))
        let recording = try Fixtures.recording([
            [
                .batch(delayMilliseconds: 10, locations: [first, duplicate]),
                .failure(delayMilliseconds: 10, error: failure),
                .batch(delayMilliseconds: 0, locations: []),
                .batch(delayMilliseconds: 10, locations: [future]),
            ],
        ], initial: Fixtures.point(latency: 2000))
        let fixture = try await Fixtures.start([recording], fidelity: .init(preserveFloor: true))
        let replay = fixture.updates[0]
        let journal = LocationReplayJournal()
        journal.connect(replay)

        #expect(replay.currentLocation?.timestamp == Fixtures.timestampOrigin.advanced(by: -2000))
        #expect(!replay.isActive)
        replay.start()
        replay.start()
        #expect(journal.order.isEmpty)
        try await fixture.clock.waitForDeadline(.milliseconds(10))
        fixture.clock.advance(to: .milliseconds(100))
        for expected in ["batch", "failure", "batch", "batch"] {
            #expect(try await journal.next() == expected)
        }
        #expect(journal.batches.map(\.count) == [2, 0, 1])
        #expect(journal.batches[0][0].timestamp == Fixtures.timestampOrigin.advanced(by: -490))
        #expect(journal.batches[0][1].timestamp == journal.batches[0][0].timestamp)
        #expect(replay.currentLocation?.timestamp == Fixtures.timestampOrigin.advanced(by: 130))
        #expect(replay.currentLocation?.floor?.level == 3)
        #expect(journal.errors.first?.domain == "fixture.location")
        #expect(journal.errors.first?.code == 7)
        #expect(journal.errors.first?.userInfo["reason"] as? String == "retry")
        #expect(replay.isActive)

        let result = await fixture.execution.finish()
        let claim = try #require(result.usage.first?.tracks.first?.claimedRecords.first)
        #expect(claim.progressCount == 4)
        #expect(claim.isConsumed)
        #expect(result.report.diagnostics.isEmpty)
        #expect(replay.isClosed)
        #expect(replay.currentLocation?.coordinate.latitude == 13)
    }

    @Test @MainActor
    func `failure preserves current location before recovery`() async throws {
        let error = try #require(NSErrorSnapshot(domain: "fixture.location", code: 1))
        let fixture = try await Fixtures.start([
            Fixtures.recording([
                [
                    .failure(delayMilliseconds: 0, error: error),
                    .batch(delayMilliseconds: 10, locations: [Fixtures.point(latitude: 2)]),
                ],
            ], initial: Fixtures.point(latitude: 1)),
        ])
        let replay = fixture.updates[0]
        let journal = LocationReplayJournal()
        let cached = replay.currentLocation
        replay.setDelivery(locations: { values in
            #expect(replay.currentLocation === values.last)
            journal.append("recovery")
        }, failure: { _ in
            #expect(replay.currentLocation === cached)
            journal.append("failure")
        })
        replay.start()
        #expect(try await journal.next() == "failure")
        try await fixture.clock.waitForDeadline(.milliseconds(10))
        fixture.clock.advance(to: .milliseconds(10))
        #expect(try await journal.next() == "recovery")
        #expect(replay.currentLocation?.coordinate.latitude == 12)
        _ = await fixture.execution.finish()
    }

    @Test @MainActor
    func `stop abandons a claim and restart anchors the next session afresh`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording([
                [
                    .batch(delayMilliseconds: 10, locations: [Fixtures.point(latitude: 1)]),
                    .batch(delayMilliseconds: 10, locations: [Fixtures.point(latitude: 2)]),
                ],
                [.batch(delayMilliseconds: 5, locations: [Fixtures.point(latitude: 3)])],
            ]),
        ])
        let replay = fixture.updates[0]
        let journal = LocationReplayJournal()
        journal.connect(replay)
        replay.stop()
        replay.start()
        try await fixture.clock.waitForDeadline(.milliseconds(10))
        fixture.clock.advance(to: .milliseconds(10))
        _ = try await journal.next()
        replay.stop()
        replay.stop()
        #expect(!replay.isActive)
        #expect(replay.currentLocation?.coordinate.latitude == 11)
        fixture.clock.advance(to: .seconds(1))
        replay.start()
        try await fixture.clock.waitForDeadline(.milliseconds(1005))
        fixture.clock.advance(to: .milliseconds(1005))
        _ = try await journal.next()
        #expect(journal.batches.map { $0.last?.coordinate.latitude } == [11, 13])
        let result = await fixture.execution.finish()
        let claims = try #require(result.usage.first?.tracks.first?.claimedRecords)
        #expect(claims.map(\.progressCount) == [1, 1])
        #expect(claims.map(\.isConsumed) == [false, true])
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test @MainActor
    func `callback can stop and restart without delivering abandoned events`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording([
                [
                    .batch(delayMilliseconds: 0, locations: [Fixtures.point(latitude: 1)]),
                    .batch(delayMilliseconds: 0, locations: [Fixtures.point(latitude: 2)]),
                ],
                [.batch(delayMilliseconds: 0, locations: [Fixtures.point(latitude: 3)])],
            ]),
        ])
        let replay = fixture.updates[0]
        let journal = LocationReplayJournal()
        replay.setDelivery(locations: { values in
            let latitude = values.last?.coordinate.latitude
            journal.append(latitude == 11 ? "first" : "second")
            if latitude == 11 {
                replay.stop()
                replay.start()
            }
        }, failure: { _ in Issue.record("Unexpected dependency failure") })
        replay.start()
        #expect(try await journal.next() == "first")
        #expect(try await journal.next() == "second")
        #expect(journal.order == ["first", "second"])
        let result = await fixture.execution.finish()
        #expect(result.usage.first?.tracks.first?.claimedRecords.map(\.isConsumed) == [false, true])
    }

    @Test @MainActor
    func `stopping within the final callback still acknowledges delivered behavior`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording([
                [
                    .batch(delayMilliseconds: 0, locations: [Fixtures.point()]),
                ],
            ]),
        ])
        let replay = fixture.updates[0]
        let journal = LocationReplayJournal()
        replay.setDelivery(locations: { _ in
            replay.stop()
            journal.append("stopped")
        }, failure: { _ in })
        replay.start()
        _ = try await journal.next()
        #expect(!replay.isActive)
        let result = await fixture.execution.finish()
        #expect(result.usage.first?.tracks.first?.claimedRecords.first?.isConsumed == true)
    }

    @Test @MainActor
    func `empty session reaches its open horizon without callback or completion`() async throws {
        let fixture = try await Fixtures.start([Fixtures.recording([[]])])
        let replay = fixture.updates[0]
        let journal = LocationReplayJournal()
        journal.connect(replay)
        replay.start()
        replay.start()
        #expect(replay.isActive)
        #expect(replay.currentLocation == nil)
        #expect(journal.order.isEmpty)
        let result = await fixture.execution.finish()
        let claim = try #require(result.usage.first?.tracks.first?.claimedRecords.first)
        #expect(claim.isConsumed)
        #expect(claim.progressCount == 0)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test @MainActor
    func `exhausted starts stay inert until stop and closed starts diagnose safely`() async throws {
        let fixture = try await Fixtures.start([Fixtures.recording([])])
        let replay = fixture.updates[0]
        let journal = LocationReplayJournal()
        journal.connect(replay)
        replay.start()
        replay.start()
        #expect(replay.isActive)
        replay.stop()
        replay.start()
        #expect(journal.order.isEmpty)
        let result = await fixture.execution.finish()
        #expect(result.report.diagnostics.count == 2)
        #expect(result.usage.first?.tracks.first?.claimedRecords.isEmpty == true)
        #expect(replay.isClosed)
        replay.setDelivery(locations: { _ in Issue.record("Closed callback") }, failure: { _ in })
        replay.stop()
        replay.start()
        #expect(!replay.isActive)
        #expect(fixture.execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
        #expect(fixture.execution.reporter.report == result.report)
    }

    @Test @MainActor
    func `keyed attachments claim independently and current reads consume nothing`() async throws {
        let recording = try Fixtures.recording([
            [
                .batch(delayMilliseconds: 0, locations: [Fixtures.point(latitude: 1)]),
            ],
        ], initial: Fixtures.point())
        let fixture = try await Fixtures.start([recording, recording])
        let journal = LocationReplayJournal()
        journal.connect(fixture.updates[0])
        for _ in 0..<3 {
            #expect(fixture.updates[1].currentLocation?.coordinate.latitude == 10)
        }
        fixture.updates[0].start()
        _ = try await journal.next()
        let result = await fixture.execution.finish()
        #expect(result.usage[0].tracks[0].claimedRecords.count == 1)
        #expect(result.usage[1].tracks[0].claimedRecords.isEmpty)
        #expect(result.usage[1].tracks[0].unclaimedRecords.count == 1)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test @MainActor
    func `pending shutdown freezes current state and concurrent finish is idempotent`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording([
                [
                    .batch(delayMilliseconds: 100, locations: [Fixtures.point(latitude: 2)]),
                ],
            ], initial: Fixtures.point(latitude: 1)),
        ])
        let replay = fixture.updates[0]
        let journal = LocationReplayJournal()
        journal.connect(replay)
        replay.start()
        try await fixture.clock.waitForDeadline(.milliseconds(100))
        let first = Task { await fixture.execution.finish() }
        let second = Task { await fixture.execution.finish() }
        second.cancel()
        let result = await first.value
        #expect(await second.value.report == result.report)
        fixture.clock.advance(to: .seconds(1))
        #expect(journal.order.isEmpty)
        #expect(replay.currentLocation?.coordinate.latitude == 11)
        #expect(result.usage.first?.tracks.first?.claimedRecords.first?.isConsumed == false)
        #expect(result.usage.first?.tracks.first?.claimedRecords.first?.progressCount == 0)
        #expect(replay.isClosed)
        #expect(fixture.controls[0].isClosed)
    }

    @Test @MainActor
    func `extreme representable delay remains pending without early delivery`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording([
                [
                    .batch(delayMilliseconds: Int64.max, locations: []),
                ],
            ]),
        ])
        let replay = fixture.updates[0]
        let journal = LocationReplayJournal()
        journal.connect(replay)
        replay.start()
        #expect(replay.isActive)
        #expect(journal.order.isEmpty)
        let result = await fixture.execution.finish()
        #expect(result.usage.first?.tracks.first?.claimedRecords.first?.isConsumed == false)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test @MainActor
    func `real monotonic replay does not deliver before its recorded delay`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording([
                [
                    .batch(delayMilliseconds: 20, locations: [Fixtures.point()]),
                ],
            ]),
        ], executionClock: .continuous())
        let journal = LocationReplayJournal()
        journal.connect(fixture.updates[0])
        let start = ContinuousClock.now
        fixture.updates[0].start()
        _ = try await journal.next()
        #expect(start.duration(to: .now) >= .milliseconds(20))
        let result = await fixture.execution.finish()
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.usage.first?.tracks.first?.claimedRecords.first?.isConsumed == true)
    }

    @Test @MainActor
    func `close releases callback captures while retaining frozen native state`() async throws {
        let fixture = try await Fixtures.start([Fixtures.recording([], initial: Fixtures.point())])
        let released = Mutex(false)
        var marker: LocationReplayMarker? = LocationReplayMarker { released.withLock { $0 = true } }
        weak let weakMarker = marker
        fixture.updates[0].setDelivery(locations: { [marker] _ in
            withExtendedLifetime(marker) {}
        }, failure: { _ in })
        marker = nil
        #expect(weakMarker != nil)
        _ = await fixture.execution.finish()
        #expect(weakMarker == nil)
        #expect(released.withLock { $0 })
        #expect(fixture.updates[0].currentLocation?.coordinate.latitude == 10)
        fixture.updates[0].close()
        #expect(fixture.updates[0].isClosed)
    }

    @Test @concurrent
    func `claimed delivery waiting for MainActor is suppressed after admission closes`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording([
                [
                    .batch(delayMilliseconds: 0, locations: [Fixtures.point()]),
                ],
            ]),
        ])
        let gate = LocationReplayBlockingGate()
        let claimed = AsyncStream<Void>.makeStream()
        let delivered = Mutex(false)
        let control = fixture.controls[0]
        let track = try control.state.withLock { state, _ in state.sessions.id }
        await fixture.updates[0].setDelivery(locations: { _ in
            delivered.withLock { $0 = true }
        }, failure: { _ in })
        let blocker = Task { @MainActor in
            fixture.updates[0].start()
            // This later due item proves the earlier Location registration has
            // been claimed while MainActor is still held by this synchronous scope.
            try control.scheduling.schedule(at: .zero, for: RecordIdentity(trackID: track, sequence: 99)) {
                claimed.continuation.finish()
            }
            gate.block()
        }
        await gate.waitForEntry()
        defer { gate.release() }
        for await _ in claimed.stream {}
        let finish = Task { await fixture.execution.finish() }
        while !control.isClosed {
            await Task.yield()
        }
        gate.release()
        try await blocker.value
        let result = await finish.value
        #expect(!delivered.withLock { $0 })
        #expect(result.usage.first?.tracks.first?.claimedRecords.first?.progressCount == 0)
        #expect(result.usage.first?.tracks.first?.claimedRecords.first?.isConsumed == false)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test @concurrent
    func `finish joins an executing main actor callback before freezing its report`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording([
                [
                    .batch(delayMilliseconds: 0, locations: [Fixtures.point()]),
                ],
            ]),
        ])
        let gate = LocationReplayBlockingGate()
        await fixture.updates[0].setDelivery(locations: { _ in gate.block() }, failure: { _ in })
        await fixture.updates[0].start()
        await gate.waitForEntry()
        let completed = Mutex(false)
        let first = Task {
            let result = await fixture.execution.finish()
            completed.withLock { $0 = true }
            return result
        }
        let canceled = Task { await fixture.execution.finish() }
        canceled.cancel()
        while !fixture.controls[0].isClosed {
            await Task.yield()
        }
        #expect(!completed.withLock { $0 })
        #expect(fixture.execution.reporter.report == nil)
        gate.release()
        let result = await first.value
        #expect(await canceled.value.report == result.report)
        #expect(result.usage.first?.tracks.first?.claimedRecords.first?.isConsumed == true)
        #expect(await fixture.updates[0].isClosed)
    }
}

private final class LocationReplayMarker: Sendable {
    let onRelease: @Sendable () -> Void
    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

private final class LocationReplayBlockingGate: Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let semaphore = DispatchSemaphore(value: 0)

    func block() {
        entered.continuation.finish()
        #expect(semaphore.wait(timeout: .now() + 10) == .success)
    }

    func waitForEntry() async {
        for await _ in entered.stream {}
    }

    func release() {
        semaphore.signal()
    }
}
