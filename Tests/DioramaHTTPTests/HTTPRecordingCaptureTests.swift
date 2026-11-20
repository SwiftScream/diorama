import DioramaCore
import DioramaHTTP
import Foundation
import HTTPTypes
import Testing

struct HTTPRecordingCaptureTests {
    typealias Fixture = HTTPRecordingFixtures

    @Test
    func `ordered conversion and decision timing`() async throws {
        let fixture = try await Fixture.start(storage: .init(fallback: .resource(), useStandardRules: false))
        let first = try fixture.begin()
        let second = try fixture.begin()
        try fixture.complete(second.initial, .request(Fixture.request(.head)))
        try fixture.observe(.failed("before head"), on: second)
        let response = try fixture.reserve(first)
        try fixture.observe(.redirect(Fixture.request(.head)), on: first)
        fixture.clock.advance(.seconds(2))
        try fixture.observe(.redirectAnswer(.followModified(Fixture.request(.post))), on: first)
        fixture.clock.advance(.milliseconds(50))
        try fixture.observe(.response(Fixture.head()), on: first, attempt: 1)
        try fixture.observe(.disposition, on: first, attempt: 1)
        try fixture.observe(.dispositionAnswer(.allow), on: first, attempt: 1)
        fixture.clock.advance(.milliseconds(10))
        try fixture.observe(.segment([0, 255]), on: first, attempt: 1)
        try fixture.observe(.returned, on: first, attempt: 1)
        try fixture.complete(response, .response(Fixture.head(302)))
        try fixture.complete(first.initial, .request(Fixture.request()))
        let records = try await fixture.finish(first)
        #expect(records.count == 2)
        guard case let .received(root) = records[0].result, case let .redirect(phase) = root.next,
              case let .followModified(request, .received(next)) = phase.outcome,
              case let .disposition(decision) = next.next, case let .allow(body) = decision.outcome,
              case let .resource(resource) = body.content,
              case let .resource(initial) = records[0].initialRequest.body,
              case let .failed(failure) = records[1].result
        else {
            Issue.record("Expected one redirect and one independent pre-head failure")
            return
        }
        #expect(initial.bytes() == [0, 255])
        #expect(initial.path != resource.path)
        #expect(records[0].initialRequest.derivesContentLength && request.derivesContentLength)
        #expect(!phase.proposedRequest.derivesContentLength)
        #expect(next.head.value.derivesContentLength)
        #expect(next.head.after.milliseconds == .observed(50))
        #expect(body.profile?.durationMilliseconds == 10)
        #expect(resource.bytes() == [0, 255])
        #expect(failure.value == "before head")
        #expect(throws: (any Error).self) { try fixture.reserve(first) }
    }

    @Test
    func `millisecond rounding preserves zero delays and cumulative timing`() async throws {
        let fixture = try await Fixture.start()
        let handle = try fixture.begin()
        try fixture.complete(handle.initial, .request(Fixture.request()))
        try fixture.observe(.response(Fixture.head()), on: handle)
        for gap in [500, 600, 500, 0] {
            fixture.clock.advance(.microseconds(gap))
            try fixture.observe(.segment([1]), on: handle)
        }
        try fixture.observe(.returned, on: handle)
        let records = try await fixture.finish(handle)
        let record = try #require(records.first)
        guard case let .received(response) = record.result else {
            Issue.record("Expected a response with timed body segments")
            return
        }
        let profile = try #require(response.body?.profile)
        #expect(profile.segments.map(\.after.milliseconds) == [.observed(1), .observed(0), .observed(1), .observed(0)])
        #expect(profile.durationMilliseconds == 2)
    }

    @Test
    func `freeze preserves each observed horizon`() async throws {
        let fixture = try await Fixture.start()
        let challenge = try Self.challenge()
        let groups: [[Fixture.Event]] = try [
            [], [.response(Fixture.head())],
            [.response(Fixture.head(302)), .redirect(Fixture.request())],
            [.response(Fixture.head(401)), .challenge(challenge)],
            [.response(Fixture.head()), .disposition],
            [.response(Fixture.head()), .disposition, .dispositionAnswer(.allow), .segment([1, 2])],
            [.response(Fixture.head(401)), .challenge(challenge), .challengeAnswer(.performDefaultHandling)],
        ]
        var handles: [HTTPCaptureOperation] = []
        for events in groups {
            let handle = try fixture.begin()
            handles.append(handle)
            try fixture.complete(handle.initial, .request(Fixture.request()))
            for event in events {
                try fixture.observe(event, on: handle)
            }
        }
        let records = try await fixture.finish(handles[0])
        guard case .openAtRecordingHorizon = records[0].result,
              case let .received(head) = records[1].result, case .openAtRecordingHorizon = head.body?.conclusion,
              case let .received(rdr) = records[2].result, case let .redirect(redirect) = rdr.next,
              case .openAtRecordingHorizon = redirect.outcome,
              case let .received(auth) = records[3].result, case let .authenticate(pending) = auth.next,
              case .openAtRecordingHorizon = pending.outcome,
              case let .received(response) = records[4].result, case let .disposition(decision) = response.next,
              case .openAtRecordingHorizon = decision.outcome,
              case let .received(allowed) = records[5].result, case .openAtRecordingHorizon = allowed.body?.conclusion,
              case let .received(handled) = records[6].result, case let .authenticate(answered) = handled.next,
              case .performDefaultHandling(.openAtRecordingHorizon) = answered.outcome
        else {
            Issue.record("Lost an observed phase at the recording horizon")
            return
        }
        #expect(allowed.body?.content == .bytes([1, 2]))
        #expect(!allowed.head.value.derivesContentLength)
    }

    private static func challenge() throws -> HTTPAuthenticationChallenge {
        try .init(method: .basic, host: "example.test", port: 443, protocol: "https", realm: nil,
                  isProxy: false, previousFailureCount: 0, proposedCredential: nil)
    }

    @Test(arguments: [nil, HTTPResponseDispositionDecision.allow, .cancel])
    func `refused redirect records disposition under the original head`(answer: HTTPResponseDispositionDecision?)
        async throws
    {
        let fixture = try await Fixture.start()
        let handle = try fixture.begin()
        try fixture.complete(handle.initial, .request(Fixture.request()))
        try fixture.observe(.response(Fixture.head(302)), on: handle)
        try fixture.observe(.redirect(Fixture.request()), on: handle)
        fixture.clock.advance(.seconds(2))
        try fixture.observe(.redirectAnswer(.refuse), on: handle)
        fixture.clock.advance(.milliseconds(30))
        try fixture.observe(.disposition, on: handle)
        if let answer {
            fixture.clock.advance(.seconds(2))
            try fixture.observe(.dispositionAnswer(answer), on: handle)
            fixture.clock.advance(.milliseconds(50))
            if answer == .allow {
                try fixture.observe(.segment([3, 4]), on: handle)
                try fixture.observe(.returned, on: handle)
            } else {
                try fixture.observe(.failed("cancel"), on: handle)
            }
        }
        let records = try await fixture.finish(handle)
        let record = try #require(records.first)
        guard case let .received(response) = record.result, case let .redirect(redirect) = response.next,
              case let .refuse(.disposition(disposition)) = redirect.outcome
        else {
            Issue.record("Expected the refused response to own its disposition")
            return
        }
        #expect(response.head.value.head.status == .found)
        #expect(disposition.after.milliseconds == .observed(30))
        switch (answer, disposition.outcome) {
        case (.none, .openAtRecordingHorizon):
            #expect(response.body == nil)
        case let (.allow, .allow(body)):
            #expect(body.content == .bytes([3, 4]))
            #expect(body.profile?.durationMilliseconds == 50)
            #expect(response.head.value.derivesContentLength)
        case let (.cancel, .cancel(failure)):
            #expect(failure.after.milliseconds == .observed(50))
            #expect(failure.value == "cancel")
            #expect(response.body == nil)
        default:
            Issue.record("Unexpected outcome for the observed disposition")
        }
    }

    @Test
    func `repeated challenges and refused redirect`() async throws {
        let fixture = try await Fixture.start()
        let handle = try fixture.begin()
        try fixture.complete(handle.initial, .request(Fixture.request(.head)))
        let challenge = try Self.challenge()
        for attempt in 0...1 {
            try fixture.observe(.response(Fixture.head(401)), on: handle, attempt: attempt)
            try fixture.observe(.challenge(challenge), on: handle, attempt: attempt)
            if attempt == 0 {
                try fixture.observe(.challengeAnswer(.useCredential(
                    .init(user: nil, hasPassword: true, persistence: .none), request: nil)), on: handle)
            } else {
                try fixture.observe(.challengeAnswer(.rejectProtectionSpace), on: handle, attempt: attempt)
                try fixture.observe(.retry(Fixture.request(.get)), on: handle, attempt: attempt)
            }
        }
        let refusal: [Fixture.Event] = try [
            .response(Fixture.head(302)), .redirect(Fixture.request(.head)),
            .redirectAnswer(.refuse), .content(.bytes([3, 4])), .returned,
        ]
        for event in refusal {
            try fixture.observe(event, on: handle, attempt: 2)
        }
        let records = try await fixture.finish(handle)
        guard case let .received(first) = records[0].result, case let .authenticate(auth) = first.next,
              case let .useCredential(_, retry) = auth.outcome, case let .received(second) = retry.result,
              case let .authenticate(repeated) = second.next,
              case let .rejectProtectionSpace(.retry(changed)) = repeated.outcome,
              case let .received(redirect) = changed.result
        else {
            Issue.record("Expected two nested retries")
            return
        }
        #expect(changed.request?.head.method == .get)
        #expect(redirect.body?.content == .bytes([3, 4]))
        #expect(redirect.head.value.derivesContentLength)
    }
}

extension HTTPRecordingCaptureTests {
    @Test
    func `body conclusions and selection`() async throws {
        let fixture = try await Fixture.start()
        let groups: [[Fixture.Event]] = try [
            [.response(Fixture.head()), .segment([0, 255]), .failed("partial")],
            [.response(Fixture.head()), .content(.unavailable), .returned],
            [.response(Fixture.head(length: "12")), .segment([0, 255]), .returned],
            [.response(Fixture.head(length: nil)), .content(.bytes([])), .returned],
            [.response(Fixture.head()), .disposition, .dispositionAnswer(.cancel), .failed("cancel")],
            [.response(Fixture.head(401)), .challenge(Self.challenge()), .challengeAnswer(.cancel), .failed("auth")],
            [.response(Fixture.head()), .segment([]), .trailers(HTTPFields()), .returned],
        ]
        var handles: [HTTPCaptureOperation] = []
        for events in groups {
            let handle = try fixture.begin()
            handles.append(handle)
            try fixture.complete(handle.initial, .request(Fixture.request()))
            for event in events {
                try fixture.observe(event, on: handle)
            }
        }
        let records = try await fixture.finish(handles[0])
        let nodes = records.compactMap {
            if case let .received(node) = $0.result {
                node
            } else {
                nil
            }
        }
        #expect(nodes.count == groups.count)
        #expect(nodes.allSatisfy { !$0.head.value.derivesContentLength })
        #expect(nodes[0].body?.content == .bytes([0, 255]))
        #expect(nodes[1].body?.content == .unavailable)
        #expect(nodes[2].head.value.head.headerFields[.contentLength] == "12")
        #expect(nodes[3].head.value.head.headerFields[.contentLength] == nil)
        guard case let .failed(partial) = nodes[0].body?.conclusion,
              case let .disposition(disposition) = nodes[4].next, case let .cancel(cancel) = disposition.outcome,
              case let .authenticate(auth) = nodes[5].next, case let .cancel(canceled) = auth.outcome,
              case let .returned(completion) = nodes[6].body?.conclusion
        else {
            Issue.record("Expected exclusive failure and success leaves")
            return
        }
        #expect([partial.value, cancel.value, canceled.value] == ["partial", "cancel", "auth"])
        #expect(completion.trailers?.fields == HTTPFields())
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5, 6])
    func `incomplete or incompatible capture blocks publication`(example: Int) async throws {
        let fixture = try await Fixture.start()
        let handle = try fixture.begin()
        try fixture.complete(handle.initial, .request(Fixture.request()))
        let expectedIssue: DiagnosticIssue
        switch example {
        case 0:
            _ = try fixture.reserve(handle)
            expectedIssue = .system(DiagnosticLabel("http.capture.pending-preparation"))
        case 1:
            #expect(throws: HTTPRecordingError.self) { try fixture.complete(handle.initial, .returned) }
            expectedIssue = .system(DiagnosticLabel("http.capture.invalid-reservation"))
        case 2:
            try fixture.observe(.response(Fixture.head()), on: handle)
            try fixture.observe(.disposition, on: handle)
            try fixture.observe(.dispositionAnswer(.cancel), on: handle)
            #expect(throws: HTTPRecordingError.self) { try fixture.observe(.returned, on: handle) }
            expectedIssue = .system(DiagnosticLabel("http.capture.incompatible-observation"))
        case 3:
            try fixture.observe(.response(Fixture.head(302)), on: handle)
            try fixture.observe(.redirect(Fixture.request()), on: handle)
            try fixture.observe(.redirectAnswer(.followProposed), on: handle)
            #expect(throws: HTTPRecordingError.self) { try fixture.observe(.failed("stale"), on: handle, attempt: 0) }
            expectedIssue = .system(DiagnosticLabel("http.capture.wrong-attempt"))
        case 4:
            try fixture.observe(.response(Fixture.head()), on: handle)
            try fixture.observe(.disposition, on: handle)
            try fixture.observe(.dispositionAnswer(.cancel), on: handle)
            expectedIssue = .system(DiagnosticLabel("http.capture.missing-completion"))
        case 5:
            try fixture.observe(.response(Fixture.head()), on: handle)
            try fixture.observe(.trailers(HTTPFields()), on: handle)
            expectedIssue = .system(DiagnosticLabel("http.capture.missing-completion"))
        default:
            try fixture.execution.state.withLock { state, operation in
                state.capture.invalidate(handle, operation: &operation)
            }
            expectedIssue = .conversionFailed
        }
        let result = await fixture.scenario.finish()
        #expect(result.definition == nil)
        let reasons = result.report.recordingHealth.failures.map(\.diagnostic)
            .filter { $0.issue != .verification(.recordingNotAdmitted) }
        #expect(reasons.count == 1)
        #expect(reasons.first?.issue == expectedIssue)
        #expect(reasons.first?.context == .record(handle.identity))
    }

    @Test
    func `preparation failure retains its original reason without captured values`() async throws {
        let fixture = try await Fixture.start()
        let handle = try fixture.begin()
        let policy = ValuePreparation<String>(redact: { _ in throw HTTPRecordingError.incompatibleObservation })
        do {
            _ = try policy.prepare(capturing: { "private credential" }, purpose: .recording,
                                   reporter: fixture.execution.reporter, context: .record(handle.identity))
            Issue.record("Expected preparation to fail")
        } catch {
            try fixture.execution.state.withLock { state, operation in
                state.capture.invalidate(handle, after: error, operation: &operation)
            }
        }
        let result = await fixture.scenario.finish()
        #expect(result.definition == nil)
        let reasons = result.report.recordingHealth.failures.map(\.diagnostic)
            .filter { $0.issue != .verification(.recordingNotAdmitted) }
        let expected = Diagnostic(issue: .preparationFailed(.redaction), context: .record(handle.identity),
                                  recordingImpact: .invalidatesCandidate)
        #expect(reasons == [expected])
        #expect(!String(describing: result.report.diagnostics).contains("private credential"))
    }

    @Test
    func `finish racing an observation produces only committed content`() async throws {
        let fixture = try await Fixture.start()
        let handle = try fixture.begin()
        try fixture.complete(handle.initial, .request(Fixture.request()))
        let failure = try fixture.reserve(handle)
        async let finished = fixture.scenario.finish()
        let admitted = (try? fixture.complete(failure, .failed("lost"))) != nil
        let result = await finished
        if admitted {
            let attachment = try #require(result.definition?.attachments.first)
            let track = try attachment.track(handle.identity.trackID, as: Fixture.Interaction.self)
            guard case let .failed(observed) = track?.records.first?.value.result else {
                Issue.record("Expected the admitted failure to survive freeze")
                return
            }
            #expect(observed.value == "lost")
        } else {
            #expect(result.definition == nil)
        }
    }
}

extension HTTPRecordingCaptureTests {
    @Test
    func `prepared bytes and effective method control automatic selection`() async throws {
        let storage = HTTPBodyStoragePolicy(fallback: .automatic(inlineByteLimit: 2), useStandardRules: false)
        let fixture = try await Fixture.start(storage: storage)
        let handle = try fixture.begin()
        let source = try Fixture.request(.post)
        let policy = ValuePreparation<HTTPRequestMessage>(redact: { try HTTPRequestMessage(head: $0.head,
                                                                                           body: .bytes([0, 255])) })
        let prepared = try policy.prepare(capturing: {
            try HTTPRequestMessage(head: source.head, body: .bytes(Array("private".utf8)))
        }, purpose: .recording, reporter: fixture.execution.reporter)
        try fixture.complete(handle.initial, .request(prepared.value))
        for attempt in 0...1 {
            try fixture.observe(.response(Fixture.head(302)), on: handle, attempt: attempt)
            try fixture.observe(.redirect(Fixture.request(.head)), on: handle, attempt: attempt)
            try fixture.observe(.redirectAnswer(.followProposed), on: handle, attempt: attempt)
        }
        try fixture.observe(.response(Fixture.head()), on: handle, attempt: 2)
        try fixture.observe(.segment([0, 255]), on: handle, attempt: 2)
        try fixture.observe(.returned, on: handle, attempt: 2)
        let records = try await fixture.finish(handle)
        #expect(records[0].initialRequest.derivesContentLength)
        #expect(records[0].initialRequest.body == .bytes([0, 255]))
        guard case let .received(first) = records[0].result, case let .redirect(edge) = first.next,
              case let .followProposed(.received(second)) = edge.outcome,
              case let .redirect(next) = second.next, case let .followProposed(.received(last)) = next.outcome
        else {
            Issue.record("Expected two followed redirects")
            return
        }
        #expect(!last.head.value.derivesContentLength)
        #expect(last.head.value.head.headerFields[.contentLength] == "2")
    }

    @Test
    func `loaded literal and inline content survive replay under resource policy`() async throws {
        let system = try ScenarioSystem(named: "http", definition: Fixture.Definition(
            storage: .init(fallback: .resource(), useStandardRules: false)))
        let trackID = try #require(system.attachment.trackIDs.first)
        let authored = try Fixture.Interaction(initialRequest: Fixture.request(), result: .openAtRecordingHorizon)
        let bytes = try JSONEncoder().encode(authored)
        let loaded = try JSONDecoder().decode(Fixture.Interaction.self, from: bytes)
        let track = try SequentialTrack(id: trackID, values: [ValuePreparation().admitPrepared(loaded)])
        let attachment = try ScenarioAttachment(id: system.attachment.id).adding(track)
        let replay = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]), scenarioID: .init(rawValue: "literal"),
            defaultMode: .replay, systems: [AnyScenarioSystem(system)])
        let consumer = try replay.dependency(system)
        let observed = try consumer.state.withLock { state, operation in try operation.consumeNext(on: state.records) }
        #expect(observed == authored)
        #expect(!observed.initialRequest.derivesContentLength)
        #expect(observed.initialRequest.body == .bytes([0, 255]))
        _ = await replay.finish()
    }
}
