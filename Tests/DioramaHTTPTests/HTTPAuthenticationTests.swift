import DioramaCore
import DioramaHTTP
import Foundation
import HTTPTypes
import Testing

struct HTTPAuthenticationTests {
    private typealias Interaction = HTTPInteraction<String>
    private typealias Result = HTTPAttemptResult<String>
    private typealias Response = HTTPResponseNode<String>
    private typealias Phase = HTTPAuthenticationPhase<String>
    private typealias Outcome = HTTPAuthenticationOutcome<String>
    private typealias Continuation = HTTPAuthenticationContinuation<String>
    private typealias Retry = HTTPAuthenticationRetry<String>
    private typealias Body = HTTPBodyDelivery<String>

    @Test
    func `independent golden preserves repeated challenges and one owning response per attempt`() throws {
        let values = try JSONDecoder().decode([Interaction].self, from: fixture())
        #expect(try canonical(values) == fixture())
        let root = try #require(values.first)
        let first = try phase(root.result)
        #expect(first.challenge.method == .basic)
        #expect(first.challenge.previousFailureCount == 0)
        #expect(first.challenge.proposedCredential == credential())
        guard case let .useCredential(user, retry) = first.outcome else {
            Issue.record("Expected a credential retry")
            return
        }
        #expect(user == credential())
        #expect(retry.request == nil)
        #expect(retry.effectiveRequest(inheriting: root.initialRequest) == root.initialRequest)
        let second = try phase(retry.result)
        #expect(second.challenge.method == .digest)
        #expect(second.challenge.previousFailureCount == 1)
        guard case let .performDefaultHandling(.deliverBody(body)) = second.outcome else {
            Issue.record("Expected the second challenge's own body")
            return
        }
        #expect(body.content == .bytes(Array("denied".utf8)))
        #expect(retry.result.responseBody == body)
        #expect(root.result.responseBody == nil)
        #expect(try object(retry).keys.sorted() == ["result"])
        #expect(try object(first.challenge).keys.sorted() == [
            "host", "isProxy", "method", "port", "previousFailureCount", "proposedCredential", "protocol", "realm",
        ])
    }

    @Test
    func `public builders reproduce the golden and preserve proxy and optional metadata`() throws {
        let values = try JSONDecoder().decode([Interaction].self, from: fixture())
        let body = try Body(content: .bytes(Array("denied".utf8)), conclusion: .returned(.init(after: delay(5))))
        let second = try received(challenge: challenge(method: .digest, count: 1, proposed: nil),
                                  outcome: .performDefaultHandling(.deliverBody(body)), headAfter: 13)
        let first = try received(challenge: challenge(), outcome: .useCredential(credential(), Retry(result: second)),
                                 headAfter: 7)
        #expect(try Interaction(initialRequest: request(), result: first) == values[0])
        let proxy = try phase(values[1].result)
        #expect(proxy.challenge.isProxy)
        #expect(proxy.challenge.protocol == nil)
        #expect(proxy.challenge.realm == "")
        #expect(proxy.challenge.proposedCredential?.user == nil)
        #expect(proxy.challenge.proposedCredential?.hasPassword == false)
        #expect(proxy.challenge.proposedCredential?.persistence == .forSession)
    }

    @Test
    func `current dispositions and every safe credential field select only one branch`() throws {
        let body = Body(content: .absent, conclusion: .openAtRecordingHorizon)
        let retry = Retry(result: .openAtRecordingHorizon)
        let outcomes: [Outcome] = try [
            .useCredential(credential(), retry), .performDefaultHandling(.deliverBody(body)),
            .rejectProtectionSpace(.failed(.init(after: delay(8), value: "rejected"))),
            .cancel(.init(after: delay(9), value: "canceled")),
        ]
        let decisions: [HTTPAuthenticationDecision] = [
            .useCredential(credential()), .performDefaultHandling, .rejectProtectionSpace, .cancel,
        ]
        for (index, outcome) in outcomes.enumerated() {
            let phase = try Phase(after: delay(2), challenge: challenge(), outcome: outcome)
            for (choice, decision) in decisions.enumerated() {
                if index == choice {
                    _ = try phase.continuation(for: decision)
                } else {
                    #expect(throws: HTTPAuthenticationSelectionError.incompatibleDecision) {
                        try phase.continuation(for: decision)
                    }
                }
            }
        }
        let phase = try Phase(after: delay(0), challenge: challenge(), outcome: outcomes[0])
        let changed: [HTTPAuthenticationCredential] = [
            credential(user: nil), credential(user: ""), credential(user: "other"),
            .init(user: "fixture-user", hasPassword: false, persistence: .none),
            credential(persistence: .forSession), credential(persistence: .permanent),
            credential(persistence: .synchronizable),
        ]
        for credential in changed {
            #expect(throws: HTTPAuthenticationSelectionError.incompatibleDecision) {
                try phase.continuation(for: .useCredential(credential))
            }
        }
        #expect(try phase.continuation(for: decisions[0]) == .retry(retry))
    }

    @Test
    func `unanswered and answered open horizons are distinct and never synthesize completion`() throws {
        let values = try JSONDecoder().decode([Interaction].self, from: fixture())
        let open = try phase(values[3].result)
        for decision in [
            HTTPAuthenticationDecision.cancel, .performDefaultHandling, .rejectProtectionSpace,
            .useCredential(credential()),
        ] {
            #expect(throws: HTTPAuthenticationSelectionError.decisionBeyondRecordingHorizon) {
                try open.continuation(for: decision)
            }
        }
        let answered = try phase(values[4].result)
        #expect(try answered.continuation(for: .rejectProtectionSpace) == .openAtRecordingHorizon)
        #expect(values[3].result.responseBody == nil)
        #expect(values[4].result.responseBody == nil)
        let canceled = try phase(values[2].result)
        #expect(try canceled.continuation(for: .cancel) == .failed(.init(after: delay(11), value: "canceled")))
        #expect(try object(canceled.outcome).keys.sorted() == ["failure", "kind"])
    }

    @Test
    func `body continuation preserves returned failed and open content without repeating head`() throws {
        for conclusion: HTTPBodyConclusion<String> in try [
            .returned(.init(
                after: delay(5),
                trailers: .init(after: delay(3), fields: HTTPFields([.init(name: .eTag, value: "end")])))),
            .failed(.init(after: delay(5), value: "lost")), .openAtRecordingHorizon,
        ] {
            let body = try Body(content: .bytes([0, 255, 65]), profile: .init(segments: [
                .init(byteWeight: 1, after: delay(2)), .init(byteWeight: 2, after: delay(3)),
            ]), conclusion: conclusion)
            for outcome: Outcome in [
                .performDefaultHandling(.deliverBody(body)),
                .rejectProtectionSpace(.deliverBody(body)),
            ] {
                let result = try received(challenge: challenge(), outcome: outcome)
                let value = try Interaction(initialRequest: request(), result: result)
                #expect(try JSONDecoder().decode(Interaction.self, from: canonical(value)) == value)
                #expect(result.responseBody == body)
                guard case let .received(response) = result else { continue }
                #expect(try object(response).keys.sorted() == ["head", "next"])
                let next = try object(response.next)
                #expect(next.keys.sorted() == ["authenticate", "kind"])
                #expect(next["kind"] as? String == "authenticate")
            }
        }
    }

    @Test
    func `timing checks stop at decisions and preserve independent maximum continuation delay`() throws {
        let phase = try Phase(after: delay(Int64.max), challenge: challenge(),
                              outcome: .cancel(.init(after: delay(Int64.max), value: "canceled")))
        _ = try Response(head: head(.unauthorized), next: .authenticate(phase))
        #expect(throws: HTTPLifecycleError.delayOverflow) {
            try Response(head: head(.unauthorized, after: 1), next: .authenticate(phase))
        }
        for _ in 0..<2 {
            #expect(try phase.continuation(for: .cancel) == .failed(.init(after: delay(Int64.max), value: "canceled")))
        }
        var encoded = try object(phase)
        encoded["after"] = ["observed": "-1ms", "override": "0.004s"]
        let edited = try decode(Phase.self, encoded)
        #expect(edited.after.milliseconds == .override(4))
        encoded["after"] = "-1ms"
        try expectCorrupt(Phase.self, encoded, path: ["after"])
    }

    @Test
    func `origin and proxy challenges require their own 401 and 407 heads`() throws {
        for proxy in [false, true] {
            let phase = try Phase(after: delay(0), challenge: challenge(proxy: proxy), outcome: .openAtRecordingHorizon)
            for status in [200, 302, 401, 403, 407, 500] {
                let head = try head(HTTPResponse.Status(code: status))
                if status == (proxy ? 407 : 401) {
                    _ = try Response(head: head, next: .authenticate(phase))
                } else {
                    #expect(throws: HTTPAuthenticationError.invalidResponse) {
                        try Response(head: head, next: .authenticate(phase))
                    }
                    try expectCorrupt(
                        Response.self,
                        ["head": object(head), "next": object(HTTPAfterResponseHead.authenticate(phase))],
                        path: ["next"])
                }
            }
        }
        #expect(throws: HTTPAuthenticationError.invalidChallenge) {
            try HTTPAuthenticationChallenge(method: .basic, host: "", port: 443, protocol: nil, realm: nil,
                                            isProxy: false, previousFailureCount: 0, proposedCredential: nil)
        }
        var metadata = try object(challenge())
        for (key, value) in [("host", "" as Any), ("port", -1), ("port", 65536), ("previousFailureCount", -1)] {
            var invalid = metadata
            invalid[key] = value
            try expectCorrupt(HTTPAuthenticationChallenge.self, invalid, path: [key])
        }
        for key in ["method", "protocol", "realm", "proposedCredential"] {
            metadata = try object(challenge())
            metadata[key] = NSNull()
            #expect(throws: (any Error).self) { try decode(HTTPAuthenticationChallenge.self, metadata) }
        }
    }

    @Test
    func `recursive method validation follows inherited and explicitly modified authentication requests`() throws {
        let raw = try Response(head: .init(after: delay(0), value: HTTPResponseHead(head: HTTPResponse(
            status: .ok, headerFields: HTTPFields([.init(name: .contentLength, value: "1")])))),
        body: .init(content: .bytes([65]), conclusion: .returned(.init(after: delay(0)))))
        let derived = try HTTPContentLength.response(ValuePreparation().admitPrepared(raw), requestMethod: .get)
        for changed in [false, true] {
            for method: HTTPRequest.Method in [.get, .head, .connect] {
                let retry = try Retry(request: changed ? request(method: method) : nil, result: .received(derived))
                for outcome: Outcome in [
                    .useCredential(credential(), retry), .performDefaultHandling(.retry(retry)),
                    .rejectProtectionSpace(.retry(retry)),
                ] {
                    let result = try received(challenge: challenge(), outcome: outcome)
                    let root = try request(method: changed ? .get : method)
                    if method == .get {
                        let value = try Interaction(initialRequest: root, result: result)
                        #expect(try JSONDecoder().decode(Interaction.self, from: canonical(value)) == value)
                    } else {
                        #expect(throws: HTTPMessageError.invalidField) { try Interaction(
                            initialRequest: root,
                            result: result) }
                        let path = ["result", "response", "next", "authenticate", "outcome"] +
                            (outcome.isUse ? [] : ["continuation"]) + [
                                "retry",
                                "result",
                                "response",
                                "head",
                                "value",
                                "fields",
                            ]
                        try expectCorrupt(
                            Interaction.self,
                            ["initialRequest": object(root), "result": object(result)],
                            path: path)
                    }
                }
            }
        }
    }

    @Test
    func `exposed challenged bodies support resource edits and derived content lengths`() throws {
        let resource = try HTTPResourceCodingFixtures.resource(path: "challenge.bin", bytes: [1, 2, 3])
        let body = try Body(content: .resource(resource), conclusion: .returned(.init(after: delay(4))))
        let phase = try Phase(
            after: delay(2),
            challenge: challenge(),
            outcome: .performDefaultHandling(.deliverBody(body)))
        let response = try Response(head: .init(after: delay(3), value: HTTPResponseHead(head: HTTPResponse(
            status: .unauthorized, headerFields: HTTPFields([.init(name: .contentLength, value: "3")])))),
        next: .authenticate(phase))
        let derived = try HTTPContentLength.response(ValuePreparation().admitPrepared(response), requestMethod: .get)
        #expect(derived.head.value.derivesContentLength)
        let edited = try HTTPResourceCodingFixtures.decoder(resources: ["challenge.bin": [5, 6, 7, 8]])
            .decode(Response.self, from: canonical(derived))
        #expect(edited.head.value.head.headerFields[.contentLength] == "4")
        #expect(try edited.body?.content == .resource(HTTPResourceCodingFixtures.resource(
            path: "challenge.bin", bytes: [5, 6, 7, 8])))
        for outcome: Outcome in try [
            .useCredential(credential(), Retry(result: .openAtRecordingHorizon)), .openAtRecordingHorizon,
            .cancel(.init(after: delay(0), value: "canceled")),
        ] {
            let next = Phase(after: phase.after, challenge: phase.challenge, outcome: outcome)
            #expect(throws: HTTPMessageError.invalidField) {
                try Response(head: derived.head, next: .authenticate(next))
            }
        }
    }

    @Test
    func `all authentication boundaries reject missing null unknown and incompatible branch fields`() throws {
        let values = try JSONDecoder().decode([Interaction].self, from: fixture())
        for value in values {
            let phase = try phase(value.result)
            try rejectEdits(Phase.self, object(phase))
            try rejectEdits(Outcome.self, object(phase.outcome))
            try rejectEdits(HTTPAfterResponseHead<String>.self, object(HTTPAfterResponseHead.authenticate(phase)))
            guard case let .received(response) = value.result else { continue }
            for key in ["body", "redirect"] {
                var competing = try object(response)
                competing[key] = [:] as [String: Any]
                #expect(throws: (any Error).self) { try decode(Response.self, competing) }
                var next = try object(response.next)
                next[key] = [:] as [String: Any]
                #expect(throws: (any Error).self) { try decode(HTTPAfterResponseHead<String>.self, next) }
            }
        }
        try rejectEdits(HTTPAuthenticationChallenge.self, object(challenge()))
        try rejectEdits(HTTPAuthenticationCredential.self, object(credential()))
        let continuations: [Continuation] = try [
            .retry(.init(request: request(), result: .openAtRecordingHorizon)),
            .deliverBody(.init(content: .absent, conclusion: .openAtRecordingHorizon)),
            .failed(.init(after: delay(1), value: "lost")), .openAtRecordingHorizon,
        ]
        for next in continuations {
            try rejectEdits(Continuation.self, object(next))
        }
        try rejectEdits(Retry.self, object(Retry(request: request(), result: .openAtRecordingHorizon)))
        for invalid: [String: Any] in try [
            ["kind": "useCredential", "credential": object(credential()), "retry": ["kind": "open"]],
            ["kind": "cancel", "failure": ["kind": "open"]],
            ["kind": "open", "continuation": ["kind": "open"]],
            ["kind": "performDefaultHandling", "continuation": ["kind": "received"]],
        ] {
            #expect(throws: (any Error).self) { try decode(Outcome.self, invalid) }
        }
        try expectCorrupt(Outcome.self, ["kind": "secret-marker"], path: ["kind"])
        try expectCorrupt(Continuation.self, ["kind": "secret-marker"], path: ["kind"])
        for key in ["password", "identity", "certificates", "failureResponse", "decisionLatency", "version"] {
            var invalid = try object(challenge())
            invalid[key] = "secret-marker"
            #expect(throws: (any Error).self) { try decode(HTTPAuthenticationChallenge.self, invalid) }
        }
        var secret = try object(credential())
        secret["password"] = "secret-marker"
        #expect(throws: (any Error).self) { try decode(HTTPAuthenticationCredential.self, secret) }
    }

    @Test
    func `authentication and redirect edges preserve the current effective request`() throws {
        let modified = try request(method: .post)
        let redirect = try HTTPRedirectPhase<String>(after: delay(4), proposedRequest: modified,
                                                     outcome: .followProposed(.openAtRecordingHorizon))
        let redirected = try Result.received(Response(head: head(.found, after: 5), next: .redirect(redirect)))
        let retry = Retry(request: modified, result: redirected)
        let result = try received(challenge: challenge(), outcome: .performDefaultHandling(.retry(retry)))
        let root = try Interaction(initialRequest: request(), result: result)
        #expect(try JSONDecoder().decode(Interaction.self, from: canonical(root)) == root)
        let answer = try phase(result).continuation(for: .performDefaultHandling)
        guard case let .retry(selected) = answer, case let .received(response) = selected.result,
              case let .redirect(next) = response.next
        else {
            Issue.record("Expected authentication retry followed by redirect")
            return
        }
        #expect(selected.effectiveRequest(inheriting: root.initialRequest) == modified)
        #expect(try next.continuation(for: .follow(modified), requestsMatch: ==) ==
            .attempt(request: modified, result: .openAtRecordingHorizon))
        #expect(response.body == nil)
    }

    @Test
    func `unknown method and persistence tags fail without rendering their values`() throws {
        var metadata = try object(challenge())
        metadata["method"] = "secret-marker"
        try expectCorrupt(HTTPAuthenticationChallenge.self, metadata, path: ["method"])
        var credential = try object(credential())
        credential["persistence"] = "secret-marker"
        try expectCorrupt(HTTPAuthenticationCredential.self, credential, path: ["persistence"])
        let empty = HTTPAuthenticationCredential(user: "", hasPassword: false, persistence: .synchronizable)
        #expect(try decode(HTTPAuthenticationCredential.self, object(empty)) == empty)
    }

    private func credential(user: String? = "fixture-user", persistence: HTTPAuthenticationPersistence = .none)
        -> HTTPAuthenticationCredential
    {
        .init(user: user, hasPassword: true, persistence: persistence)
    }

    private func challenge(method: HTTPAuthenticationMethod = .basic, count: Int = 0, proxy: Bool = false,
                           proposed: HTTPAuthenticationCredential? = .init(
                               user: "fixture-user",
                               hasPassword: true,
                               persistence: .none))
        throws -> HTTPAuthenticationChallenge
    {
        try .init(method: method, host: "example.invalid", port: 443, protocol: "https", realm: "fixture",
                  isProxy: proxy, previousFailureCount: count, proposedCredential: proposed)
    }

    private func request(method: HTTPRequest.Method = .get) throws -> HTTPRequestMessage {
        try .init(
            head: HTTPRequest(method: method, scheme: "https", authority: "example.invalid", path: "/private"),
            body: .absent)
    }

    private func delay(_ value: Int64) throws -> HTTPDelay {
        try .init(milliseconds: .observed(value))
    }

    private func head(_ status: HTTPResponse.Status, after: Int64 = 0) throws -> HTTPTimed<HTTPResponseHead> {
        try .init(after: delay(after), value: HTTPResponseHead(head: HTTPResponse(status: status)))
    }

    private func received(challenge: HTTPAuthenticationChallenge, outcome: Outcome,
                          headAfter: Int64 = 0) throws -> Result
    {
        try .received(Response(
            head: head(challenge.isProxy ? .proxyAuthenticationRequired : .unauthorized, after: headAfter),
            next: .authenticate(Phase(after: delay(2), challenge: challenge, outcome: outcome))))
    }

    private func phase(_ result: Result) throws -> Phase {
        guard case let .received(response) = result, case let .authenticate(phase) = response.next else {
            throw TestError.expectedChallenge
        }
        return phase
    }

    private enum TestError: Error { case expectedChallenge }

    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "authentication",
            withExtension: "json",
            subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func canonical(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data([10])
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: canonical(value)) as? [String: Any])
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ value: [String: Any]) throws -> Value {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    private func rejectEdits(_ type: (some Decodable).Type, _ value: [String: Any]) throws {
        for key in value.keys.sorted() {
            // These fields are optional by deliberate omission, never explicit null.
            if !["user", "protocol", "realm", "proposedCredential", "request"].contains(key) {
                var missing = value
                missing.removeValue(forKey: key)
                #expect(throws: (any Error).self) { try decode(type, missing) }
            }
            var nulled = value
            nulled[key] = NSNull()
            #expect(throws: (any Error).self) { try decode(type, nulled) }
        }
        var unknown = value
        unknown["unknown"] = true
        #expect(throws: (any Error).self) { try decode(type, unknown) }
    }

    private func expectCorrupt(_ type: (some Decodable).Type, _ value: [String: Any], path: [String]) throws {
        do {
            _ = try decode(type, value)
            Issue.record("Expected structural failure")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == path)
            #expect(!context.debugDescription.contains("secret-marker"))
        }
    }
}

private extension HTTPAuthenticationOutcome where Failure == String {
    var isUse: Bool {
        if case .useCredential = self {
            true
        } else {
            false
        }
    }
}

private extension HTTPAttemptResult where Failure == String {
    var responseBody: HTTPBodyDelivery<String>? {
        if case let .received(response) = self {
            response.body
        } else {
            nil
        }
    }
}
