import DioramaCore
import DioramaHTTP
import Foundation
import HTTPTypes
import Testing

struct HTTPRecordingMergeTests {
    typealias Interaction = HTTPInteraction<String>
    typealias Next = HTTPAfterResponseHead<String>
    typealias Body = HTTPBodyDelivery<String>

    private let id = TrackID(attachmentID: AttachmentID(systemTypeID: .init(rawValue: "http"),
                                                        key: .init(rawValue: "service")),
                             key: .init(rawValue: "interactions"))

    @Test(arguments: ["lifecycle", "redirects", "authentication"])
    func `every authored delay in the version one fixture survives at its own path`(_ fixture: String) throws {
        let resource = Bundle.module.url(forResource: fixture, withExtension: "json", subdirectory: "Fixtures")
        let source = try Data(contentsOf: #require(resource))
        let decoder = HTTPResourceCodingFixtures.decoder(resources: ["bodies/reply.bin": [1, 2, 3]])
        let json = try JSONSerialization.jsonObject(with: source)
        // Assign a different authored value to each delay directly in the persisted fixture.
        // This oracle is independent of the domain traversal and catches interchanged paths.
        var count = 0
        let baselineData = try JSONSerialization.data(withJSONObject: replacingDelays(in: json) {
            count += 1
            return ["override": "\(count)ms"]
        })
        let freshData = try JSONSerialization.data(withJSONObject: replacingDelays(in: json) { "0ms" })
        let original = try decoder.decode([Interaction].self, from: baselineData)
        let fresh = try decoder.decode([Interaction].self, from: freshData)
        var facts: [Diagnostic] = []
        let candidate = try merge(original, fresh) { facts.append($0) }
        #expect(candidate == original)
        #expect(count > 0 && facts.count == count)
        #expect(facts.allSatisfy { $0.issue == .system(DiagnosticLabel("http.timing-override-retained")) })
    }

    @Test
    func `body replacement preserves only compatible segment positions and conclusion kinds`() throws {
        let old = try profile([1, 2, 3], weights: [10, 20, 30], authored: true)
        let new = try profile([4, 5], weights: [2, 1], authored: false)
        let content = try HTTPResourceCodingFixtures.resource(path: "private/replacement.bin", bytes: [5, 6])
        let baseline = try Body(content: .bytes([1]), profile: old, conclusion: .failed(
            HTTPTimed(after: delay(7, authored: true), value: "private-failure")))
        let completion = try HTTPBodyCompletion(after: delay(8))
        let fresh = try Body(content: .resource(content), profile: new, conclusion: .returned(completion))
        let expected = try Body(content: .resource(content), profile: profile([1, 2], weights: [2, 1], authored: true),
                                conclusion: .returned(completion))
        var facts: [Diagnostic] = []
        let result = try merge([response(.deliverBody(baseline))], [response(.deliverBody(fresh))]) { facts.append($0) }
        #expect(try result == [response(.deliverBody(expected))])
        let obsolete = facts.filter { $0.issue == .system(DiagnosticLabel("http.timing-override-obsolete")) }
        #expect(obsolete.map { $0.fieldPath.map(\.text) } == [["body", "segments", "2"], ["body", "failure"]])
    }

    @Test
    func `same-shaped redirect continuations on different branches cannot exchange overrides`() throws {
        let oldFailure = try HTTPTimed(after: delay(7, authored: true), value: "old")
        let newFailure = try HTTPTimed(after: delay(8), value: "new")
        let old = try HTTPRedirectPhase(after: delay(3, authored: true), proposedRequest: request("/old"),
                                        outcome: .followProposed(.failed(oldFailure)))
        let new = try HTTPRedirectPhase(after: delay(4), proposedRequest: request("/new"),
                                        outcome: .followModified(request("/modified"), .failed(newFailure)))
        let expected = HTTPRedirectPhase(after: old.after, proposedRequest: new.proposedRequest, outcome: new.outcome)
        #expect(try merge([response(.redirect(old))], [response(.redirect(new))]) == [response(.redirect(expected))])
    }

    @Test
    func `refused redirect timing keeps direct and disposition delivery paths separate`() throws {
        let oldBody = try Body(content: .absent, conclusion: .returned(.init(after: delay(4, authored: true))))
        let freshBody = try Body(content: .absent, conclusion: .returned(.init(after: delay(8))))
        let recorded = try HTTPResponseDispositionPhase(after: delay(2, authored: true), outcome: .allow(oldBody))
        let proposal = try request("/redirect")
        let baseline = try HTTPRedirectPhase(after: delay(3, authored: true), proposedRequest: proposal,
                                             outcome: .refuse(.disposition(recorded)))
        let fresh = try HTTPRedirectPhase(after: delay(5), proposedRequest: proposal,
                                          outcome: .refuse(.deliverBody(freshBody)))
        let expected = HTTPRedirectPhase(after: baseline.after, proposedRequest: proposal, outcome: fresh.outcome)
        var facts: [Diagnostic] = []
        let result = try merge([response(.redirect(baseline))], [response(.redirect(fresh))]) { facts.append($0) }
        #expect(try result == [response(.redirect(expected))])
        let obsolete = facts.filter { $0.issue == .system(DiagnosticLabel("http.timing-override-obsolete")) }
        #expect(obsolete.map { $0.fieldPath.map(\.text) } == [
            ["redirect", "refuse", "disposition"], ["redirect", "refuse", "disposition", "allow", "completion"],
        ])
    }

    @Test
    func `authentication default and reject failures have different paths`() throws {
        let challenge = try HTTPAuthenticationChallenge(method: .basic, host: "service", port: 443, protocol: nil,
                                                        realm: nil, isProxy: false, previousFailureCount: 0,
                                                        proposedCredential: nil)
        let old = try HTTPAuthenticationPhase(after: delay(2, authored: true), challenge: challenge,
                                              outcome: .performDefaultHandling(.failed(.init(
                                                  after: delay(7, authored: true), value: "old"))))
        let newFailure = try HTTPTimed(after: delay(6), value: "new")
        let new = try HTTPAuthenticationPhase(after: delay(4), challenge: challenge,
                                              outcome: .rejectProtectionSpace(.failed(newFailure)))
        let expected = HTTPAuthenticationPhase(after: old.after, challenge: challenge, outcome: new.outcome)
        let result = try merge([response(.authenticate(old))], [response(.authenticate(new))])
        #expect(try result == [response(.authenticate(expected))])
    }

    @Test
    func `disposition owns its presentation and the selected branch owns its delays`() throws {
        let body = try Body(content: .absent, conclusion: .returned(.init(after: delay(4, authored: true))))
        let old = try HTTPResponseDispositionPhase(after: delay(2, authored: true), outcome: .allow(body))
        let cancel = try HTTPResponseDispositionOutcome.cancel(HTTPTimed(after: delay(5), value: "canceled"))
        let new = try HTTPResponseDispositionPhase(after: delay(3), outcome: cancel)
        let expected = HTTPResponseDispositionPhase(after: old.after, outcome: cancel)
        let result = try merge([response(.disposition(old))], [response(.disposition(new))])
        #expect(try result == [response(.disposition(expected))])
        let ordinary = try response(.deliverBody(Body(content: .absent, conclusion: .returned(.init(after: delay(8))))))
        #expect(try merge([response(.disposition(old))], [ordinary]) == [ordinary])
        let canceled = try HTTPTimed(after: delay(9, authored: true), value: "canceled")
        let authoredCancel = try HTTPResponseDispositionPhase(after: delay(2, authored: true),
                                                              outcome: .cancel(canceled))
        #expect(try merge([response(.disposition(authoredCancel))], [response(.disposition(new))])
            == [response(.disposition(authoredCancel))])
    }

    @Test
    func `current field policy and resolved body bytes determine correspondence`() throws {
        let resource = try HTTPResourceCodingFixtures.resource(path: "private/input", bytes: [1])
        let prior = try request("/one", tag: "old", body: .resource(resource))
        let current = try request("/one", tag: "fresh", body: .bytes([1]))
        let old = try HTTPTimed(after: delay(2, authored: true), value: "private-old")
        let new = try HTTPTimed(after: delay(3), value: "fresh")
        let baseline = try Interaction(initialRequest: prior, result: .failed(old))
        let fresh = try Interaction(initialRequest: current, result: .failed(new))
        #expect(try merge([baseline], [fresh]) == [fresh])
        let expected = try Interaction(initialRequest: current,
                                       result: .failed(.init(after: old.after, value: "fresh")))
        let matcher = HTTPRequestMatcher(fields: .including([]))
        #expect(try merge([baseline], [fresh], matcher: matcher) == [expected])
        let edited = try Interaction(initialRequest: request("/one", body: .bytes([2])), result: .failed(new))
        #expect(try merge([baseline], [edited], matcher: matcher) == [edited])
    }

    @Test
    func `custom equivalence pairs distinct projections in stable occurrence order`() throws {
        let matcher = HTTPRequestMatcher { $0.method == $1.method }
        func record(_ path: String, _ timing: HTTPDelay) throws -> Interaction {
            try Interaction(initialRequest: request(path), result: .failed(.init(after: timing, value: path)))
        }
        let first = try delay(5, authored: true)
        let second = try delay(7, authored: true)
        let fresh = try [record("/b", delay(1)), record("/a", delay(2)), record("/extra", delay(3))]
        let baseline = try [record("/a", first), record("/b", second)]
        #expect(try merge(baseline, fresh, matcher: matcher) == [record("/b", first), record("/a", second), fresh[2]])
        var facts: [Diagnostic] = []
        #expect(try merge(baseline, [], matcher: matcher) { facts.append($0) }.isEmpty)
        #expect(facts.map { $0.context.recordIdentity?.sequence } == [0, 1])
        #expect(facts.allSatisfy { $0.issue == .system(DiagnosticLabel("http.timing-override-obsolete")) })
    }

    @Test
    func `individually valid timings can overflow only after the merge`() throws {
        let baselineBody = try Body(content: .absent, conclusion: .returned(.init(after: delay(0))))
        let freshBody = try Body(content: .absent, conclusion: .returned(.init(after: delay(1))))
        let baseline = try response(.deliverBody(baselineBody), headDelay: delay(.max, authored: true))
        let fresh = try response(.deliverBody(freshBody))
        #expect(throws: HTTPLifecycleError.delayOverflow) { try merge([baseline], [fresh]) }
    }

    private func response(_ next: Next, headDelay: HTTPDelay? = nil) throws -> Interaction {
        let responseHead = HTTPResponseHead(head: .init(status: .unauthorized))
        let head = try HTTPTimed(after: headDelay ?? delay(0), value: responseHead)
        return try Interaction(initialRequest: request("/root"), result: .received(.init(head: head, next: next)))
    }

    private func request(_ path: String, tag: String? = nil, body: HTTPRequestBody = .absent) throws
        -> HTTPRequestMessage
    {
        var head = HTTPRequest(method: .get, scheme: "https", authority: "service", path: path)
        head.headerFields[.accept] = tag
        return try HTTPRequestMessage(head: head, body: body)
    }

    private func delay(_ value: Int64, authored: Bool = false) throws -> HTTPDelay {
        try HTTPDelay(milliseconds: authored ? .override(value) : .observed(value))
    }

    private func profile(_ delays: [Int64], weights: [Int64], authored: Bool) throws -> HTTPBodyProfile {
        try HTTPBodyProfile(segments: zip(delays, weights).map {
            try HTTPBodySegment(byteWeight: $1, after: delay($0, authored: authored))
        })
    }

    private func merge(_ original: [Interaction], _ fresh: [Interaction], matcher: HTTPRequestMatcher = .init(),
                       report: (Diagnostic) -> Void = { _ in }) throws -> [Interaction]
    {
        func track(_ values: [Interaction]) throws -> HeaderlessSequentialTrack<Interaction> {
            try .init(id: id, values: values.map { try ValuePreparation().admitPrepared($0) })
        }
        return try HTTPRecordingMerge(matcher: matcher).merge(baseline: track(original), fresh: track(fresh),
                                                              report: report).records.map(\.value)
    }

    private func replacingDelays(in value: Any, with delay: () -> Any) -> Any {
        if let array = value as? [Any] {
            return array.map { replacingDelays(in: $0, with: delay) }
        }
        guard var object = value as? [String: Any] else { return value }
        for key in object.keys.sorted() {
            object[key] = key == "after" ? delay() : object[key].map { replacingDelays(in: $0, with: delay) }
        }
        return object
    }
}
