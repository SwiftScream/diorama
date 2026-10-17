import CoreLocation
@testable import DioramaCore
@testable import DioramaLocation
import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LocationAccessReplayTests {
    private typealias Fixtures = LocationAccessReplayFixtures

    @Test @MainActor
    func `external changes preserve duplicates and install complete state before callbacks`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording(notifications: [
                .init(delayMilliseconds: 10, state: Fixtures.disabled),
                .init(delayMilliseconds: 20, state: Fixtures.disabled),
                .init(delayMilliseconds: 0, state: Fixtures.always),
            ]),
        ])
        let replay = fixture.access[0]
        let journal = LocationAccessReplayJournal()
        #expect(replay.currentState.servicesEnabled)
        #expect(replay.currentState.permission == .notDetermined)
        #expect(replay.currentState.accuracy == .fullAccuracy)
        journal.connect(replay)
        #expect(journal.states.isEmpty)
        try await fixture.clock.waitForDeadline(.milliseconds(10))
        fixture.clock.advance(to: .milliseconds(100))
        for expected in [Fixtures.disabled, Fixtures.disabled, Fixtures.always] {
            #expect(try await journal.next() == LocationAccessState(expected))
        }
        #expect(journal.states.count == 3)
        #expect(replay.currentState == LocationAccessState(Fixtures.always))
        let result = await fixture.execution.finish()
        let claims = try #require(result.usage.first?.tracks[1].claimedRecords)
        #expect(claims.map(\.progressCount) == [3])
        #expect(claims.map(\.isConsumed) == [true])
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test @MainActor
    func `initial and notified when in use presentation preserves request identity`() async throws {
        let recording = try Fixtures.recording(initialState: Fixtures.whenInUse, requests: [
            .init(request: .whenInUse, notifications: [.init(delayMilliseconds: 0, state: Fixtures.whenInUse)]),
        ])
        let fixture = try await Fixtures.start([recording])
        let replay = fixture.access[0]
        #if os(macOS)
            let expected = CLAuthorizationStatus.authorizedAlways
        #else
            let expected = CLAuthorizationStatus.authorizedWhenInUse
        #endif
        #expect(replay.currentState.permission == expected)
        let journal = LocationAccessReplayJournal()
        journal.connect(replay)
        replay.request(.always)
        #expect(journal.states.isEmpty)
        replay.request(.whenInUse)
        #expect(try await journal.next().permission == expected)
        #expect(recording.initialState.permission == .whenInUse)
        #expect(recording.requests[0].request == .whenInUse)
        let result = await fixture.execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.sequential(.selection(.noMatch))])
        #expect(result.usage[0].tracks[1].claimedRecords.map(\.isConsumed) == [true, true])
    }

    @Test @MainActor
    func `wrong early and duplicate requests cannot skip barriers or alter timing`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording(notifications: [
                .init(delayMilliseconds: 10, state: Fixtures.initial),
            ], requests: [
                .init(request: .whenInUse, notifications: [
                    .init(delayMilliseconds: 20, state: Fixtures.whenInUse),
                    .init(delayMilliseconds: 10, state: Fixtures.whenInUse),
                ]),
                .init(request: .always, notifications: [.init(delayMilliseconds: 5, state: Fixtures.always)]),
                .init(request: .whenInUse, notifications: []),
            ]),
        ])
        let replay = fixture.access[0]
        let journal = LocationAccessReplayJournal()
        replay.request(.always) // Observation has not reached any barrier.
        journal.connect(replay)
        replay.request(.whenInUse) // Initial notification is still pending.
        try await fixture.clock.waitForDeadline(.milliseconds(10))
        fixture.clock.advance(to: .milliseconds(10))
        _ = try await journal.next()
        replay.request(.always) // Must not select the later matching record.
        fixture.clock.advance(to: .seconds(1))
        replay.request(.whenInUse)
        replay.request(.whenInUse) // A duplicate cannot claim the third segment.
        try await fixture.clock.waitForDeadline(.milliseconds(1020))
        fixture.clock.advance(to: .milliseconds(1020))
        _ = try await journal.next()
        replay.request(.always) // The first segment still has a notification.
        try await fixture.clock.waitForDeadline(.milliseconds(1030))
        fixture.clock.advance(to: .seconds(2))
        _ = try await journal.next()
        replay.request(.always)
        try await fixture.clock.waitForDeadline(.milliseconds(2005))
        fixture.clock.advance(to: .milliseconds(2005))
        _ = try await journal.next()
        replay.request(.always) // The reached barrier expects when-in-use.
        replay.request(.whenInUse)
        replay.request(.whenInUse) // Exhaustion remains nonthrowing and offline.

        let result = await fixture.execution.finish()
        let usage = result.usage[0].tracks[1]
        #expect(usage.claimedRecords.map(\.identity.sequence) == [0, 1, 2, 3])
        #expect(usage.claimedRecords.map(\.progressCount) == [1, 2, 1, 0])
        #expect(usage.claimedRecords.allSatisfy(\.isConsumed) == true)
        #expect(result.report.diagnostics.count == 7)
        for retained in result.report.diagnostics {
            #expect(retained.diagnostic.issue == .sequential(.selection(.noMatch)))
            #expect(retained.diagnostic.context == .track(usage.id))
            #expect(retained.diagnostic.rule == DiagnosticLabel("location-authorization-barrier"))
            #expect(retained.diagnostic.fieldPath == [DiagnosticLabel("request")])
        }
    }

    @Test @MainActor
    func `current reads leave observation and requests entirely unused`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording(requests: [
                .init(request: .whenInUse, notifications: []), .init(request: .always, notifications: []),
            ]),
        ])
        for _ in 0..<3 {
            #expect(fixture.access[0].currentState.permission == .notDetermined)
        }
        let result = await fixture.execution.finish()
        #expect(result.usage[0].tracks[1].claimedRecords.isEmpty)
        #expect(result.usage[0].tracks[1].unclaimedRecords.map(\.sequence) == [0, 1, 2])
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test @MainActor
    func `expected requests never made remain independent unused records`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording(notifications: [
                .init(delayMilliseconds: 0, state: Fixtures.disabled),
            ], requests: [
                .init(request: .whenInUse, notifications: [.init(delayMilliseconds: 0, state: Fixtures.whenInUse)]),
                .init(request: .always, notifications: []),
            ]),
        ])
        let journal = LocationAccessReplayJournal()
        journal.connect(fixture.access[0])
        _ = try await journal.next()
        fixture.clock.advance(to: .seconds(10))
        let result = await fixture.execution.finish()
        #expect(journal.states == [LocationAccessState(Fixtures.disabled)])
        #expect(result.usage[0].tracks[1].claimedRecords.map(\.identity.sequence) == [0])
        #expect(result.usage[0].tracks[1].claimedRecords.first?.isConsumed == true)
        #expect(result.usage[0].tracks[1].unclaimedRecords.map(\.sequence) == [1, 2])
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test @MainActor
    func `empty segments acknowledge each recorded request without synthesizing notifications`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording(requests: [
                .init(request: .whenInUse, notifications: []), .init(request: .whenInUse, notifications: []),
            ]),
        ])
        let journal = LocationAccessReplayJournal()
        journal.connect(fixture.access[0])
        fixture.access[0].request(.whenInUse)
        fixture.access[0].request(.whenInUse)
        let result = await fixture.execution.finish()
        #expect(journal.states.isEmpty)
        #expect(result.usage[0].tracks[1].claimedRecords.map(\.progressCount) == [0, 0, 0])
        #expect(result.usage[0].tracks[1].claimedRecords.map(\.isConsumed) == [true, true, true])
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test @MainActor
    func `final callbacks can request the next segment and close without duplicate delivery`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording(notifications: [
                .init(delayMilliseconds: 0, state: Fixtures.initial),
                .init(delayMilliseconds: 0, state: Fixtures.disabled),
            ], requests: [
                .init(request: .whenInUse, notifications: [.init(delayMilliseconds: 0, state: Fixtures.whenInUse)]),
                .init(request: .always, notifications: [.init(delayMilliseconds: 0, state: Fixtures.always)]),
                .init(request: .always, notifications: []),
            ]),
        ])
        let replay = fixture.access[0]
        let journal = LocationAccessReplayJournal()
        replay.observe {
            journal.append(replay.currentState)
            switch journal.states.count {
            case 1: replay.request(.whenInUse) // Still early within this segment.
            case 2: replay.request(.whenInUse)
            case 3: replay.request(.always)
            case 4: replay.close()
            default: Issue.record("Duplicate access delivery")
            }
        }
        #expect(journal.states.isEmpty)
        for expected in [Fixtures.initial, Fixtures.disabled, Fixtures.whenInUse, Fixtures.always] {
            #expect(try await journal.next() == LocationAccessState(expected))
        }
        let result = await fixture.execution.finish()
        #expect(result.usage[0].tracks[1].claimedRecords.map(\.progressCount) == [2, 1, 1])
        #expect(result.usage[0].tracks[1].claimedRecords.map(\.isConsumed) == [true, true, true])
        #expect(result.usage[0].tracks[1].unclaimedRecords.map(\.sequence) == [3])
        #expect(result.report.diagnostics.count == 1)
        #expect(replay.isClosed)
    }

    @Test @MainActor
    func `replacing observation preserves the claim position and pending deadlines`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording(notifications: [
                .init(delayMilliseconds: 10, state: Fixtures.disabled),
                .init(delayMilliseconds: 10, state: Fixtures.always),
            ]),
        ])
        let replay = fixture.access[0]
        let journal = LocationAccessReplayJournal()
        replay.observe { Issue.record("Replaced callback ran") }
        try await fixture.clock.waitForDeadline(.milliseconds(10))
        fixture.clock.advance(to: .milliseconds(5))
        replay.observe {
            journal.append(replay.currentState)
            journal.connect(replay)
        }
        fixture.clock.advance(to: .milliseconds(10))
        #expect(try await journal.next() == LocationAccessState(Fixtures.disabled))
        try await fixture.clock.waitForDeadline(.milliseconds(20))
        fixture.clock.advance(to: .milliseconds(20))
        #expect(try await journal.next() == LocationAccessState(Fixtures.always))
        let result = await fixture.execution.finish()
        #expect(result.usage[0].tracks[1].claimedRecords.count == 1)
        #expect(result.usage[0].tracks[1].claimedRecords.first?.progressCount == 2)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test @MainActor
    func `attachments retain independent access states and request positions`() async throws {
        let recording = try Fixtures.recording(requests: [
            .init(request: .whenInUse, notifications: [.init(delayMilliseconds: 0, state: Fixtures.whenInUse)]),
        ])
        let fixture = try await Fixtures.start([recording, recording])
        let journal = LocationAccessReplayJournal()
        journal.connect(fixture.access[0])
        journal.connect(fixture.access[1])
        fixture.access[0].request(.whenInUse)
        _ = try await journal.next()
        #expect(fixture.access[0].currentState == LocationAccessState(Fixtures.whenInUse))
        #expect(fixture.access[1].currentState == LocationAccessState(Fixtures.initial))
        let result = await fixture.execution.finish()
        #expect(result.usage[0].tracks[1].claimedRecords.map(\.identity.sequence) == [0, 1])
        #expect(result.usage[1].tracks[1].claimedRecords.map(\.identity.sequence) == [0])
        #expect(result.usage[1].tracks[1].unclaimedRecords.map(\.sequence) == [1])
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test @MainActor
    func `partial notification delivery remains claimed but unconsumed on close`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording(notifications: [
                .init(delayMilliseconds: 0, state: Fixtures.disabled),
                .init(delayMilliseconds: 100, state: Fixtures.always),
            ], requests: [.init(request: .always, notifications: [])]),
        ])
        let replay = fixture.access[0]
        let journal = LocationAccessReplayJournal()
        journal.connect(replay)
        _ = try await journal.next()
        try await fixture.clock.waitForDeadline(.milliseconds(100))
        replay.close()
        replay.close()
        fixture.clock.advance(to: .seconds(1))
        let result = await fixture.execution.finish()
        #expect(journal.states == [LocationAccessState(Fixtures.disabled)])
        #expect(replay.currentState == LocationAccessState(Fixtures.disabled))
        #expect(result.usage[0].tracks[1].claimedRecords.first?.progressCount == 1)
        #expect(result.usage[0].tracks[1].claimedRecords.first?.isConsumed == false)
        #expect(result.usage[0].tracks[1].unclaimedRecords.map(\.sequence) == [1])
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test(arguments: [false, true]) @MainActor
    func `pending shutdown freezes state and canceled finish waiters share the final report`(afterRequest: Bool)
        async throws
    {
        let notifications = [LocationAccessNotification(delayMilliseconds: 100, state: Fixtures.always)]
        let recording = try Fixtures.recording(
            notifications: afterRequest ? [] : notifications,
            requests: [.init(request: .always, notifications: afterRequest ? notifications : [])])
        let fixture = try await Fixtures.start([recording])
        let replay = fixture.access[0]
        let journal = LocationAccessReplayJournal()
        journal.connect(replay)
        if afterRequest {
            replay.request(.always)
        }
        try await fixture.clock.waitForDeadline(.milliseconds(100))
        let first = Task { await fixture.execution.finish() }
        let canceled = Task { await fixture.execution.finish() }
        canceled.cancel()
        let result = await first.value
        #expect(await canceled.value.report == result.report)
        fixture.clock.advance(to: .seconds(1))
        replay.observe { Issue.record("Closed observation delivered") }
        replay.request(.always)
        #expect(journal.states.isEmpty)
        #expect(replay.currentState == LocationAccessState(Fixtures.initial))
        #expect(replay.isClosed)
        let claims = result.usage[0].tracks[1].claimedRecords
        #expect(claims.count == (afterRequest ? 2 : 1))
        #expect(claims.last?.progressCount == 0)
        #expect(claims.last?.isConsumed == false)
        #expect(result.report.diagnostics.isEmpty)
        #expect(fixture.execution.reporter.report == result.report)
        #expect(fixture.execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.lifecycle(.leaseClosed)])
    }

    @Test @MainActor
    func `close releases callback captures while retaining frozen native state`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording(),
        ])
        let replay = fixture.access[0]
        let released = Mutex(false)
        var marker: LocationReplayMarker? = LocationReplayMarker { released.withLock { $0 = true } }
        weak let weakMarker = marker
        replay.observe { [marker] in withExtendedLifetime(marker) {} }
        marker = nil
        #expect(weakMarker != nil)
        _ = await fixture.execution.finish()
        #expect(weakMarker == nil)
        #expect(released.withLock { $0 })
        #expect(replay.isClosed)
        #expect(replay.currentState == LocationAccessState(Fixtures.initial))
    }

    @Test @MainActor
    func `extreme valid access delay stays pending until canceled`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording(notifications: [
                .init(delayMilliseconds: Int64.max, state: Fixtures.always),
            ]),
        ])
        let journal = LocationAccessReplayJournal()
        journal.connect(fixture.access[0])
        let result = await fixture.execution.finish()
        #expect(journal.states.isEmpty)
        #expect(result.usage[0].tracks[1].claimedRecords.first?.isConsumed == false)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test @MainActor
    func `real monotonic request delay does not deliver early or inline`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording(requests: [
                .init(request: .always, notifications: [.init(delayMilliseconds: 20, state: Fixtures.always)]),
            ]),
        ], executionClock: .continuous())
        let journal = LocationAccessReplayJournal()
        journal.connect(fixture.access[0])
        let start = ContinuousClock.now
        fixture.access[0].request(.always)
        #expect(journal.states.isEmpty)
        _ = try await journal.next()
        #expect(start.duration(to: .now) >= .milliseconds(20))
        let result = await fixture.execution.finish()
        #expect(result.usage[0].tracks[1].claimedRecords.allSatisfy(\.isConsumed) == true)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test @concurrent
    func `claimed access delivery queued on MainActor is suppressed after admission closes`() async throws {
        let fixture = try await Fixtures.start([
            Fixtures.recording(notifications: [
                .init(delayMilliseconds: 0, state: Fixtures.always),
            ]),
        ])
        let gate = LocationReplayBlockingGate()
        let claimed = AsyncStream<Void>.makeStream()
        let delivered = Mutex(false)
        let control = fixture.controls[0]
        let track = try control.state.withLock { state, _ in state.access.id }
        let blocker = Task { @MainActor in
            fixture.access[0].observe { delivered.withLock { $0 = true } }
            // The later item proves the earlier access delivery was claimed
            // while this synchronous scope still occupies MainActor.
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
        #expect(result.usage[0].tracks[1].claimedRecords.first?.progressCount == 0)
        #expect(result.usage[0].tracks[1].claimedRecords.first?.isConsumed == false)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test(arguments: [false, true]) @concurrent
    func `finish joins executing access callbacks before report freeze`(hasFollowingNotification: Bool)
        async throws
    {
        var notifications = [LocationAccessNotification(delayMilliseconds: 0, state: Fixtures.always)]
        if hasFollowingNotification {
            notifications.append(.init(delayMilliseconds: 100, state: Fixtures.disabled))
        }
        let fixture = try await Fixtures.start([Fixtures.recording(notifications: notifications)])
        let gate = LocationReplayBlockingGate()
        await fixture.access[0].observe { gate.block() }
        await gate.waitForEntry()
        defer { gate.release() }
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
        #expect(result.usage[0].tracks[1].claimedRecords.first?.progressCount == 1)
        #expect(result.usage[0].tracks[1].claimedRecords.first?.isConsumed == !hasFollowingNotification)
        #expect(await fixture.access[0].currentState == LocationAccessState(Fixtures.always))
        #expect(await fixture.access[0].isClosed)
        #expect(result.report.diagnostics.isEmpty)
    }
}
