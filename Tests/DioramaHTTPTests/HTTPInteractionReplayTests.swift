import DioramaCore
import DioramaHTTP
import HTTPTypes
import Synchronization
import Testing

struct HTTPInteractionReplayTests {
    typealias Fixture = HTTPReplayFixtures
    typealias Event = Fixture.Event

    @Test(arguments: [100, 1900])
    func `current answers anchor authentication then redirect and disposition`(wait: Int) async throws {
        let fixture = try await Fixture.start([authenticationThenRefusedRedirect()])
        let events = Mutex<[String]>([])
        let done = AsyncStream<Void>.makeStream()
        _ = try await fixture.replay.start(matching: fixture.request) { event in
            do {
                switch event {
                case let .response(head, request):
                    events.withLock { $0.append("head-\(head.head.status.code)") }
                    if head.head.status.code == 302 {
                        #expect(request.head.method == .post)
                        #expect(fixture.clock.now == .milliseconds(100 + wait + 50))
                    }
                case let .authenticate(_, answer):
                    events.withLock { $0.append("auth") }
                    fixture.clock.advance(.milliseconds(wait))
                    try await answer(ValuePreparation().admitPrepared(.performDefaultHandling))
                    // Delivery latency after the answer must not shift the next deadline.
                    fixture.clock.advance(.milliseconds(15))
                    #expect(events.withLock { $0.last } == "auth")
                case let .redirect(_, answer):
                    events.withLock { $0.append("redirect") }
                    fixture.clock.advance(.milliseconds(70))
                    try await answer(ValuePreparation().admitPrepared(.refuse))
                    #expect(events.withLock { $0.last } == "redirect")
                case let .disposition(answer):
                    events.withLock { $0.append("disposition") }
                    #expect(fixture.clock.now == .milliseconds(250 + wait))
                    fixture.clock.advance(.milliseconds(90))
                    try await answer(ValuePreparation().admitPrepared(.allow))
                    #expect(events.withLock { $0.last } == "disposition")
                case .returned:
                    #expect(fixture.clock.now == .milliseconds(360 + wait))
                    events.withLock { $0.append("returned") }
                    done.continuation.finish()
                default: Issue.record("Unexpected replay event")
                }
            } catch { Issue.record(error); done.continuation.finish() }
        }
        for await _ in done.stream {}
        let result = await fixture.scenario.finish()
        #expect(events.withLock { $0 } == ["head-401", "auth", "head-302", "redirect", "disposition", "returned"])
        let claim = try #require(result.usage[0].tracks[0].claimedRecords.first)
        #expect(claim.isConsumed && claim.progressCount == 6)
    }

    private func authenticationThenRefusedRedirect() throws -> HTTPAttemptResult<String> {
        let proposal = try HTTPRecordingFixtures.request()
        let returned = try HTTPBodyDelivery<String>(content: .absent,
                                                    conclusion: .returned(.init(after: Fixture.delay(20))))
        let disposition = try HTTPResponseDispositionPhase(after: Fixture.delay(30), outcome: .allow(returned))
        let redirect = try HTTPResponseNode<String>(head: Fixture.head(302, 50), next: .redirect(.init(
            after: Fixture.delay(0), proposedRequest: proposal, outcome: .refuse(.disposition(disposition)))))
        let retry = try HTTPAuthenticationRetry(
            request: HTTPRecordingFixtures.request(.post), result: .received(redirect))
        return try .received(HTTPResponseNode(head: Fixture.head(401, 100), next: .authenticate(.init(
            after: Fixture.delay(0), challenge: Fixture.challenge(),
            outcome: .performDefaultHandling(.retry(retry))))))
    }

    @Test(arguments: [true, false])
    func `disposition body allocates edited bytes and preserves partial conclusion`(fails: Bool) async throws {
        let profile = try HTTPBodyProfile(segments: [
            .init(byteWeight: 1, after: HTTPDelay(milliseconds: .override(7))),
            .init(byteWeight: 2, after: Fixture.delay(3)),
        ])
        let resource = try HTTPResourceCodingFixtures.resource(path: "edited.bin", bytes: [1, 2, 3, 4, 5, 6])
        let failure = try HTTPTimed(after: Fixture.delay(0), value: "lost")
        let body = try HTTPBodyDelivery<String>(content: .resource(resource), profile: profile,
                                                conclusion: fails ? .failed(failure) : .openAtRecordingHorizon)
        let head = try HTTPResponseNode(head: Fixture.head(), next: .disposition(.init(
            after: Fixture.delay(0),
            outcome: .allow(body))))
        let fixture = try await Fixture.start([.received(head)])
        let deliveries = Mutex<[[UInt8]]>([])
        let done = AsyncStream<Void>.makeStream()
        _ = try await fixture.replay.start(matching: fixture.request) { event in
            switch event {
            case .response: break
            case let .disposition(answer):
                do {
                    try await answer(ValuePreparation().admitPrepared(.allow))
                } catch { Issue.record(error); done.continuation.finish() }
            case let .bytes(bytes):
                deliveries.withLock { $0.append(Array(bytes)) }
                #expect(fixture.clock.now == .milliseconds(bytes.count == 2 ? 7 : 10))
                if bytes.count == 4, !fails {
                    done.continuation.finish()
                }
            case let .failed(value):
                #expect(fails && value == "lost")
                done.continuation.finish()
            default: Issue.record("Unexpected body conclusion"); done.continuation.finish()
            }
        }
        for await _ in done.stream {}
        let result = await fixture.scenario.finish()
        #expect(deliveries.withLock { $0 } == [[1, 2], [3, 4, 5, 6]])
        #expect(result.usage[0].tracks[0].claimedRecords.first?.isConsumed == true)
    }
}

extension HTTPInteractionReplayTests {
    @Test
    func `a call without a response decision fails before the head and preserves later matches`() async throws {
        let delay = try Fixture.delay(0)
        let body = try HTTPBodyDelivery<String>(content: .bytes(Array("hello".utf8)),
                                                conclusion: .returned(.init(after: delay)))
        let outcomes: [HTTPResponseDispositionOutcome<String>] = [
            .allow(body), .cancel(.init(after: delay, value: "canceled")), .openAtRecordingHorizon,
        ]
        let decisions = try outcomes.map {
            try HTTPAttemptResult.received(HTTPResponseNode(head: Fixture.head(),
                                                            next: .disposition(.init(after: delay, outcome: $0))))
        }
        let plain = try HTTPAttemptResult.received(HTTPResponseNode(head: Fixture.head(), body: body))
        let fixture = try await Fixture.start(decisions + [plain])
        for _ in outcomes {
            await #expect(throws: HTTPReplayError.responseDecisionUnavailable) {
                try await fixture.replay.start(matching: fixture.request, decisionPresentation: .unavailable) { _ in
                    Issue.record("An incompatible response reached the caller")
                }
            }
        }
        let done = AsyncStream<Void>.makeStream()
        let received = Mutex<[UInt8]>([])
        _ = try await fixture.replay.start(matching: fixture.request, decisionPresentation: .unavailable) { event in
            switch event {
            case .response: break
            case let .bytes(data): received.withLock { $0.append(contentsOf: data) }
            case .returned: done.continuation.finish()
            default: Issue.record("Unexpected plain response event"); done.continuation.finish()
            }
        }
        for await _ in done.stream {}
        let result = await fixture.scenario.finish()
        #expect(received.withLock { $0 } == Array("hello".utf8))
        let claims = result.usage[0].tracks[0].claimedRecords
        #expect(claims.map(\.isConsumed) == [false, false, false, true])
        #expect(claims.map(\.progressCount) == [0, 0, 0, 3])
        let facts = result.report.diagnostics.map(\.diagnostic)
        #expect(facts.map(\.context.recordIdentity) == claims.dropLast().map(\.identity))
        #expect(facts.allSatisfy { $0.issue == .system(DiagnosticLabel("http.response-decision-unavailable")) })
    }

    @Test
    func `a refused redirect rejects a disposition the call cannot present`() async throws {
        let fixture = try await Fixture.start([authenticationThenRefusedRedirect()])
        let decisions = AsyncStream<HTTPReplayAnswer<HTTPRedirectDecision>>.makeStream()
        _ = try await fixture.replay.start(matching: fixture.request, decisionPresentation: .unavailable) { event in
            switch event {
            case .response: break
            case let .authenticate(_, answer):
                do {
                    try await answer(ValuePreparation().admitPrepared(.performDefaultHandling))
                } catch {
                    Issue.record(error)
                    decisions.continuation.finish()
                }
            case let .redirect(_, answer): decisions.continuation.yield(answer)
            default: Issue.record("Unexpected handoff"); decisions.continuation.finish()
            }
        }
        var iterator = decisions.stream.makeAsyncIterator()
        let answer = try #require(await iterator.next())
        await #expect(throws: HTTPReplayError.responseDecisionUnavailable) {
            try await answer(ValuePreparation().admitPrepared(.refuse))
        }
        let result = await fixture.scenario.finish()
        let claims = result.usage[0].tracks[0].claimedRecords
        #expect(claims.map(\.isConsumed) == [false])
        let issue = DiagnosticIssue.system(DiagnosticLabel("http.response-decision-unavailable"))
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [issue])
    }

    @Test(arguments: [true, false])
    func `late answer reports mismatch or horizon and preserves claim`(open: Bool) async throws {
        let body = HTTPBodyDelivery<String>(content: .absent, conclusion: .openAtRecordingHorizon)
        let phase = try HTTPRedirectPhase(after: Fixture.delay(0), proposedRequest: HTTPRecordingFixtures.request(),
                                          outcome: open ? .openAtRecordingHorizon : .refuse(.deliverBody(body)))
        let root = try HTTPResponseNode(head: Fixture.head(302), next: .redirect(phase))
        let fixture = try await Fixture.start([.received(root), .failed(.init(after: Fixture.delay(0), value: "next"))])
        let presentations = AsyncStream<HTTPReplayAnswer<HTTPRedirectDecision>>.makeStream()
        let first = try await fixture.replay.start(matching: fixture.request) { event in
            switch event {
            case let .redirect(_, answer): presentations.continuation.yield(answer)
            case .response: break
            default: Issue.record("Unexpected continuation")
            }
        }
        var presented = presentations.stream.makeAsyncIterator()
        let answer = try #require(await presented.next())
        let choice = try ValuePreparation<HTTPRedirectDecision>().admitPrepared(.follow(fixture.request.value))
        await #expect(throws: open ? HTTPReplayError.decisionBeyondRecordingHorizon : .incompatibleDecision) {
            try await answer(choice)
        }
        let done = AsyncStream<Void>.makeStream()
        let second = try await fixture.replay.start(matching: fixture.request) { event in
            guard case .failed("next") = event else { Issue.record("Expected pre-head failure"); return }
            done.continuation.finish()
        }
        #expect(first.identity.sequence == 0 && second.identity.sequence == 1)
        for await _ in done.stream {}
        let result = await fixture.scenario.finish()
        let claims = result.usage[0].tracks[0].claimedRecords
        #expect(claims.map(\.isConsumed) == [open, true])
        #expect(claims.map(\.progressCount) == [2, 1])
        let label = DiagnosticLabel(open ? "http.decision.beyondHorizon" : "http.decision.mismatch")
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.system(label)])
    }

    @Test(arguments: [true, false])
    func `canceled decisions deliver only the recorded failure`(auth: Bool) async throws {
        let failure = try HTTPTimed(after: Fixture.delay(3), value: "canceled")
        let next: HTTPAfterResponseHead<String> = try auth
            ? .authenticate(.init(after: Fixture.delay(0), challenge: Fixture.challenge(), outcome: .cancel(failure)))
            : .disposition(.init(after: Fixture.delay(0), outcome: .cancel(failure)))
        let fixture = try await Fixture.start([.received(.init(head: Fixture.head(401), next: next))])
        let done = AsyncStream<Void>.makeStream()
        _ = try await fixture.replay.start(matching: fixture.request) { event in
            do {
                switch event {
                case .response: break
                case let .authenticate(_, answer): try await answer(ValuePreparation().admitPrepared(.cancel))
                case let .disposition(answer): try await answer(ValuePreparation().admitPrepared(.cancel))
                case let .failed(value):
                    #expect(value == "canceled" && fixture.clock.now == .milliseconds(3))
                    done.continuation.finish()
                default: Issue.record("Unexpected cancellation continuation")
                }
            } catch { Issue.record(error); done.continuation.finish() }
        }
        for await _ in done.stream {}
        let result = await fixture.scenario.finish()
        #expect(result.usage[0].tracks[0].claimedRecords.first?.isConsumed == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func `follow-up scheduling failure ends replay with one infrastructure event`() async throws {
        let body = try HTTPBodyDelivery<String>(content: .absent,
                                                conclusion: .returned(.init(after: Fixture.delay(1))))
        let fixture = try await Fixture.start([.received(.init(head: Fixture.head(200, 1), body: body))])
        let errors = Mutex<[HTTPReplayError]>([])
        let done = AsyncStream<Void>.makeStream()
        let operation = try await fixture.replay.start(matching: fixture.request) { event in
            switch event {
            case .response:
                // The scheduler read 1 ms to hand off the head. Its next registration must reject 0 ms.
                fixture.clock.advance(.milliseconds(-1))
            case let .infrastructureFailure(error):
                errors.withLock { $0.append(error) }
                done.continuation.finish()
            default:
                Issue.record("Expected replay to end with a scheduling failure")
                done.continuation.finish()
            }
        }
        for await _ in done.stream {}
        fixture.clock.advance(.milliseconds(1))
        let result = await fixture.scenario.finish()
        #expect(errors.withLock { $0 } == [.schedulingFailed])
        let claim = try #require(result.usage[0].tracks[0].claimedRecords.first)
        #expect(claim.progressCount == 1 && !claim.isConsumed)
        #expect(result.report.diagnostics.map(\.diagnostic) == [
            Diagnostic(issue: .scheduling(.logicalTime(.clockMovedBackward)), context: .record(operation.identity)),
        ])
    }

    @Test(arguments: [true, false])
    func `stopping during handoff preserves progress and stops future delivery`(cancel: Bool) async throws {
        let body = try HTTPBodyDelivery<String>(content: .bytes([123]),
                                                conclusion: .returned(.init(after: Fixture.delay(0))))
        let fixture = try await Fixture.start([.received(.init(head: Fixture.head(), body: body))])
        let received = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let operation = try await fixture.replay.start(matching: fixture.request) { event in
            guard case .response = event else { Issue.record("Delivery continued after cancellation"); return }
            received.continuation.finish()
            for await _ in release.stream {}
        }
        for await _ in received.stream {}
        if cancel {
            await operation.cancel()
        } else {
            await fixture.replay.close()
        }
        release.continuation.finish()
        let result = await fixture.scenario.finish()
        let claim = try #require(result.usage[0].tracks[0].claimedRecords.first)
        #expect(claim.progressCount == 1 && !claim.isConsumed)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test
    func `finalization releases unanswered barrier and freezes usage`() async throws {
        let root = try HTTPResponseNode<String>(head: Fixture.head(), next: .disposition(.init(
            after: Fixture.delay(0), outcome: .allow(.init(content: .absent, conclusion: .openAtRecordingHorizon)))))
        let fixture = try await Fixture.start([.openAtRecordingHorizon, .received(root)])
        _ = try await fixture.replay.start(matching: fixture.request) { _ in Issue.record("Unexpected open callback") }
        let presentations = AsyncStream<HTTPReplayAnswer<HTTPResponseDispositionDecision>>.makeStream()
        _ = try await fixture.replay.start(matching: fixture.request) { event in
            switch event {
            case .response: break
            case let .disposition(answer): presentations.continuation.yield(answer)
            default: Issue.record("Unexpected post-horizon delivery")
            }
        }
        var iterator = presentations.stream.makeAsyncIterator()
        let answer = try #require(await iterator.next())
        let result = await fixture.scenario.finish()
        await #expect(throws: (any Error).self) { try await answer(ValuePreparation().admitPrepared(.allow)) }
        #expect(result.usage[0].tracks[0].claimedRecords.map(\.isConsumed) == [true, false])
        #expect(result.usage[0].tracks[0].claimedRecords.map(\.progressCount) == [0, 2])
    }
}

extension HTTPInteractionReplayTests {
    @Test
    func `modified redirect matches prepared fields and delivers trailers`() async throws {
        var head = try HTTPRecordingFixtures.request(.post).head
        head.path = "/edited"
        let modified = try HTTPRequestMessage(head: head)
        let trailers = try HTTPTrailers(after: Fixture.delay(4), fields: [.eTag: "final"])
        let returned = try HTTPBodyDelivery<String>(content: .bytes([7]), conclusion: .returned(.init(
            after: Fixture.delay(3), trailers: trailers)))
        let final = try HTTPResponseNode(head: Fixture.head(), body: returned)
        let root = try HTTPResponseNode<String>(head: Fixture.head(302), next: .redirect(.init(
            after: Fixture.delay(0), proposedRequest: HTTPRecordingFixtures.request(),
            outcome: .followModified(modified, .received(final)))))
        let fixture = try await Fixture.start([.received(root)])
        let done = AsyncStream<Void>.makeStream()
        let order = Mutex<[String]>([])
        _ = try await fixture.replay.start(matching: fixture.request) { event in
            do {
                switch event {
                case let .response(head, request):
                    order.withLock { $0.append("head") }
                    if head.head.status.code == 200 {
                        #expect(request == modified)
                    }
                case let .redirect(_, answer):
                    var current = modified.head
                    current.headerFields[.userAgent] = "current agent"
                    try await answer(ValuePreparation().admitPrepared(.follow(HTTPRequestMessage(head: current))))
                case let .bytes(bytes):
                    #expect(Array(bytes) == [7])
                    order.withLock { $0.append("bytes") }
                case let .trailers(fields):
                    #expect(fields[.eTag] == "final" && fixture.clock.now == .milliseconds(4))
                    order.withLock { $0.append("trailers") }
                case .returned:
                    #expect(fixture.clock.now == .milliseconds(7))
                    order.withLock { $0.append("returned") }
                    done.continuation.finish()
                default: Issue.record("Unexpected redirect continuation")
                }
            } catch { Issue.record(error); done.continuation.finish() }
        }
        for await _ in done.stream {}
        let result = await fixture.scenario.finish()
        #expect(order.withLock { $0 } == ["head", "head", "bytes", "trailers", "returned"])
        #expect(result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
    }
}

private final class ReplayDeliveryOwner: Sendable {
    func deliver(_: HTTPReplayEvent<String>) {
        Issue.record("Unexpected delivery at the open horizon")
    }
}

extension HTTPInteractionReplayTests {
    @Test(arguments: [true, false])
    func `open horizon retains delivery until cancellation or finish`(cancel: Bool) async throws {
        let fixture = try await Fixture.start([.openAtRecordingHorizon])
        weak var retained: ReplayDeliveryOwner?
        let operation: HTTPReplayOperation
        do {
            let owner = ReplayDeliveryOwner()
            retained = owner
            operation = try await fixture.replay.start(matching: fixture.request, deliver: owner.deliver)
        }
        #expect(retained != nil)
        if cancel {
            await operation.cancel()
            #expect(retained == nil)
        }
        let result = await fixture.scenario.finish()
        #expect(retained == nil)
        #expect(result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
    }
}

extension HTTPInteractionReplayTests {
    @Test
    func `credential retry and follow reach success only through current answers`() async throws {
        let credential = HTTPAuthenticationCredential(user: "prepared", hasPassword: true, persistence: .none)
        let proposed = try HTTPRecordingFixtures.request(.post)
        let body = try HTTPBodyDelivery<String>(content: .absent,
                                                conclusion: .returned(.init(after: Fixture.delay(0))))
        let final = try HTTPResponseNode(head: Fixture.head(), body: body)
        let redirect = try HTTPResponseNode<String>(head: Fixture.head(302), next: .redirect(.init(
            after: Fixture.delay(0), proposedRequest: proposed, outcome: .followProposed(.received(final)))))
        let root = try HTTPResponseNode<String>(head: Fixture.head(401), next: .authenticate(.init(
            after: Fixture.delay(0), challenge: Fixture.challenge(),
            outcome: .useCredential(credential, .init(result: .received(redirect))))))
        let fixture = try await Fixture.start([.received(root)])
        let events = AsyncStream<Event>.makeStream()
        _ = try await fixture.replay.start(matching: fixture.request) { events.continuation.yield($0) }
        var iterator = events.stream.makeAsyncIterator()
        guard case .response = await iterator.next(),
              case let .authenticate(_, authenticate) = await iterator.next()
        else {
            Issue.record("Expected authentication at the initial head")
            return
        }
        let use = try ValuePreparation<HTTPAuthenticationDecision>().admitPrepared(.useCredential(credential))
        try await authenticate(use)
        guard case let .response(_, inherited) = await iterator.next(),
              case let .redirect(proposal, follow) = await iterator.next()
        else {
            Issue.record("Expected redirect after retry")
            return
        }
        #expect(inherited == fixture.request.value && proposed == proposal)
        await #expect(throws: HTTPReplayError.inactive) { try await authenticate(use) }
        try await follow(ValuePreparation().admitPrepared(.follow(proposal)))
        guard case let .response(_, effective) = await iterator.next(), case .returned = await iterator.next() else {
            Issue.record("Expected followed attempt to return")
            return
        }
        #expect(effective == proposed)
        let result = await fixture.scenario.finish()
        #expect(result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(result.usage[0].tracks[0].claimedRecords.first?.progressCount == 6)
    }
}
