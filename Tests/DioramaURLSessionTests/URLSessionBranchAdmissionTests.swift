import DioramaCore
import DioramaHTTP
import DioramaPersistence
import DioramaURLSession
import HTTPTypes
import Testing

struct URLSessionBranchAdmissionTests {
    typealias Failure = URLSessionFailure
    typealias Result = HTTPAttemptResult<Failure>

    let schema = URLSessionRecordingSchema.standard
    let key = AttachmentKey(rawValue: "network")

    @Test
    func `derived requirements follow modified and refused redirects and open decisions`() throws {
        let post = try request(.post, body: .bytes([]))
        let delay = try HTTPDelay(milliseconds: .observed(0))
        let failed = try HTTPTimed(after: delay, value: Failure(domain: "offline", code: 1))
        let partial = HTTPBodyDelivery(content: .bytes([1]), conclusion: .failed(failed))
        let branches: [(HTTPRedirectOutcome<Failure>, Set<URLSessionReplayCapability>)] = [
            (.followModified(post, .failed(failed)), [.requestMethod("POST"), .requestBody, .failure]),
            (.refuse(.deliverBody(partial)), [.responseBody, .failure]),
            (.refuse(.disposition(.init(after: delay, outcome: .allow(partial)))),
             [.responseDecision, .responseBody, .failure]),
            (.refuse(.disposition(.init(after: delay, outcome: .cancel(failed)))),
             [.responseDecision, .dispositionCancellation, .failure]),
            (.refuse(.disposition(.init(after: delay, outcome: .openAtRecordingHorizon))),
             [.responseDecision, .openHorizon]),
            (.openAtRecordingHorizon, [.openHorizon]),
        ]
        for (outcome, requirements) in branches {
            let phase = try HTTPRedirectPhase(after: delay, proposedRequest: request(), outcome: outcome)
            try check(response(.found, .redirect(phase)), requires: requirements.union([.redirect(status: 302)]))
        }
    }

    @Test
    func `challenge requirements cover retry requests response prefixes cancellation and horizons`() throws {
        let delay = try HTTPDelay(milliseconds: .observed(0))
        let failure = try HTTPTimed(after: delay, value: Failure(domain: "auth", code: 2))
        let challenge = try HTTPAuthenticationChallenge(method: .basic, host: "proxy.invalid", port: 443,
                                                        protocol: "https", realm: nil, isProxy: true,
                                                        previousFailureCount: 1, proposedCredential: nil)
        let retry = try HTTPAuthenticationRetry<Failure>(request: request(.post, body: .bytes([1])),
                                                         result: .openAtRecordingHorizon)
        let prefix = HTTPBodyDelivery<Failure>(content: .bytes([0]), conclusion: .openAtRecordingHorizon)
        let branches: [(HTTPAuthenticationOutcome<Failure>, Set<URLSessionReplayCapability>)] = [
            (.rejectProtectionSpace(.retry(retry)), [.requestMethod("POST"), .requestBody, .openHorizon]),
            (.performDefaultHandling(.deliverBody(prefix)), [.responseBody, .openHorizon]),
            (.performDefaultHandling(.failed(failure)), [.failure]),
            (.rejectProtectionSpace(.openAtRecordingHorizon), [.openHorizon]),
            (.cancel(failure), [.failure]),
            (.openAtRecordingHorizon, [.openHorizon]),
        ]
        for (outcome, requirements) in branches {
            let phase = HTTPAuthenticationPhase(after: delay, challenge: challenge, outcome: outcome)
            try check(response(.proxyAuthenticationRequired, .authenticate(phase)),
                      requires: requirements.union([.authentication(.basic, isProxy: true)]))
        }
    }

    @Test
    func `disposition gating and cancellation apply only to observed decisions`() throws {
        let delay = try HTTPDelay(milliseconds: .observed(0))
        let failure = try HTTPTimed(after: delay, value: Failure(domain: "canceled", code: 1))
        try check(response(.ok, .disposition(.init(after: delay, outcome: .cancel(failure)))),
                  requires: [.responseDecision, .dispositionCancellation, .failure])
        try check(response(.ok, .disposition(.init(after: delay, outcome: .openAtRecordingHorizon))),
                  requires: [.responseDecision, .openHorizon])
        let completion = try HTTPBodyCompletion(after: delay)
        let body = HTTPBodyDelivery<Failure>(content: .unavailable, conclusion: .returned(completion))
        try check(response(.ok, .disposition(.init(after: delay, outcome: .allow(body)))),
                  requires: [.responseDecision])
        try check(response(.unauthorized, .deliverBody(body)), requires: [])
    }

    @Test
    func `authored requests and trailers enforce URLSession scope and field policy`() throws {
        let delay = try HTTPDelay(milliseconds: .observed(0))
        let trailers = HTTPTrailers(after: delay, fields: [.authorization: "Bearer confidential"])
        let completion = try HTTPBodyCompletion(after: delay, trailers: trailers)
        let response = try response(.ok, .deliverBody(.init(content: .absent, conclusion: .returned(completion))))
        let interaction = try HTTPInteraction(initialRequest: request(), result: response)
        #expect(throws: URLSessionRecordingError.self) {
            try schema.attachment(key: key, interactions: [interaction])
        }
        let ftp = HTTPRequest(method: .get, scheme: "ftp", authority: "example.invalid", path: "/")
        let invalid = try HTTPInteraction<Failure>(initialRequest: HTTPRequestMessage(head: ftp),
                                                   result: .openAtRecordingHorizon)
        #expect(throws: URLSessionRecordingError.self) {
            try schema.attachment(key: key, interactions: [invalid])
        }
        let empty = try schema.attachment(key: key, interactions: [])
        #expect(throws: PersistentSystemEncodingError.invalidTrackLayout(empty.id)) {
            try schema.replayTrack(in: ScenarioAttachment(id: empty.id), supporting: [])
        }
    }

    private func check(_ result: Result, requires extra: Set<URLSessionReplayCapability>) throws {
        let value = try HTTPInteraction(initialRequest: request(), result: result)
        let attachment = try schema.attachment(key: key, interactions: [value])
        let supported = extra.union([.requestMethod("GET")])
        #expect(try schema.replayTrack(in: attachment, supporting: supported).records.map(\.value) == [value])
        for capability in supported {
            #expect(throws: URLSessionRecordingError.self) {
                try schema.replayTrack(in: attachment, supporting: supported.subtracting([capability]))
            }
        }
    }

    private func request(_ method: HTTPRequest.Method = .get, body: HTTPRequestBody = .absent) throws
        -> HTTPRequestMessage
    {
        let head = HTTPRequest(method: method, scheme: "https", authority: "example.invalid", path: "/")
        return try HTTPRequestMessage(head: head, body: body)
    }

    private func response(_ status: HTTPResponse.Status, _ next: HTTPAfterResponseHead<Failure>) throws -> Result {
        let head = HTTPResponseHead(head: HTTPResponse(status: status))
        return try .received(HTTPResponseNode(head: .init(after: HTTPDelay(milliseconds: .observed(0)), value: head),
                                              next: next))
    }
}
