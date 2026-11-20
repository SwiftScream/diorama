import DioramaCore
import DioramaHTTP
import Foundation
import HTTPTypes
import Testing

struct HTTPRedirectTests {
    private typealias Interaction = HTTPInteraction<String>
    private typealias Result = HTTPAttemptResult<String>
    private typealias Response = HTTPResponseNode<String>
    private typealias Phase = HTTPRedirectPhase<String>
    private typealias Outcome = HTTPRedirectOutcome<String>
    private typealias Delivery = HTTPBodyDelivery<String>

    @Test
    func `canonical multi-hop fixture owns proposals modified requests and responses once`() throws {
        let data = try fixture()
        let values = try JSONDecoder().decode([Interaction].self, from: data)
        #expect(try canonical(values) == data)
        let first = try #require(values.first)
        #expect(try first.initialRequest == request("/start", method: .post, body: .bytes([1, 2])))
        let outer = try redirect(first.result)
        #expect(try outer.proposedRequest == request("/next"))
        #expect(outer.effectiveRequest == outer.proposedRequest)
        let selected = try outer.continuation(for: .follow(request("/next")), requestsMatch: ==)
        guard case let .attempt(nextRequest, nextResult) = selected else {
            Issue.record("Expected first followed attempt")
            return
        }
        #expect(nextRequest.body == .absent)
        let inner = try redirect(nextResult)
        let modified = try request("/modified", method: .post, body: .bytes(Array("edited".utf8)))
        #expect(try inner.proposedRequest == request("/last", method: .post, body: .bytes([3])))
        #expect(inner.effectiveRequest == modified)
        let continuation = try inner.continuation(for: .follow(modified), requestsMatch: ==)
        guard case let .attempt(effective, .received(final)) = continuation else {
            Issue.record("Expected modified request and final response")
            return
        }
        #expect(effective == modified)
        #expect(final.body?.content == .bytes(Array("done".utf8)))
        #expect(final.head.after.milliseconds == .observed(17))
        #expect(outer.after.milliseconds == .observed(2))
        #expect(inner.after.milliseconds == .override(4))
        let root = try object(first)
        let result = try #require(root["result"] as? [String: Any])
        let response = try #require(result["response"] as? [String: Any])
        let next = try #require(response["next"] as? [String: Any])
        let phase = try #require(next["redirect"] as? [String: Any])
        let outcome = try #require(phase["outcome"] as? [String: Any])
        #expect(response.keys.sorted() == ["head", "next"])
        #expect(next.keys.sorted() == ["kind", "redirect"])
        #expect(next["kind"] as? String == "redirect")
        #expect(outcome.keys.sorted() == ["kind", "result"])
        #expect(try object(inner.outcome).keys.sorted() == ["kind", "request", "result"])
    }

    @Test
    func `public builders produce the independently authored redirect golden`() throws {
        let values = try JSONDecoder().decode([Interaction].self, from: fixture())
        let final = try received(status: .ok, after: 17, body: .init(
            content: .bytes(Array("done".utf8)), conclusion: .returned(.init(after: delay(5)))))
        let inner = try Phase(
            after: HTTPDelay(milliseconds: .override(4)),
            proposedRequest: request("/last", method: .post, body: .bytes([3])),
            outcome: .followModified(request("/modified", method: .post, body: .bytes(Array("edited".utf8))), final))
        let next = try Result.received(Response(head: timed(.temporaryRedirect, after: 11), next: .redirect(inner)))
        let outer = try Phase(after: delay(2), proposedRequest: request("/next"), outcome: .followProposed(next))
        let built = try Interaction(
            initialRequest: request("/start", method: .post, body: .bytes([1, 2])),
            result: .received(Response(head: timed(.found, after: 7), next: .redirect(outer))))
        #expect(built == values[0])
        #expect(try canonical(built) == canonical(values[0]))
    }

    @Test
    func `refusal exposes only its owning response with returned failed or open prefixes`() throws {
        let values = try JSONDecoder().decode([Interaction].self, from: fixture())
        for index in [1, 5, 6] {
            guard case let .received(response) = values[index].result else {
                Issue.record("Expected redirect response")
                continue
            }
            let phase = try redirect(values[index].result)
            #expect(phase.effectiveRequest == nil)
            let continuation = try phase.continuation(for: .refuse, requestsMatch: { _, _ in
                Issue.record("Refusal must not compare requests")
                return false
            })
            guard case let .deliverBody(body) = continuation else {
                Issue.record("Expected refusal body under the original head")
                continue
            }
            #expect(body == response.body)
            #expect(response.head.value.head.status == .found)
            #expect(try object(phase.outcome).keys.sorted() == ["kind", "next"])
        }
        let returned = try #require(values[1].result.responseBody)
        #expect(returned.content == .bytes(Array("redirect".utf8)))
        #expect(returned.profile?.segments.map(\.byteWeight) == [2, 6])
        guard case let .returned(completion) = returned.conclusion else {
            Issue.record("Expected completed refusal")
            return
        }
        #expect(try completion.trailers?.fields[#require(HTTPField.Name("X-End"))] == "done")
        #expect(try values[5].result.responseBody?.conclusion == .failed(.init(after: delay(9), value: "lost")))
        #expect(values[6].result.responseBody?.conclusion == .openAtRecordingHorizon)
    }

    @Test
    func `refusal selects the recorded disposition under the same response head`() throws {
        let values = try JSONDecoder().decode([Interaction].self, from: fixture())
        let value = try #require(values.last)
        let phase = try redirect(value.result)
        let selected = try phase.continuation(for: .refuse, requestsMatch: ==)
        guard case let .disposition(disposition) = selected, case let .received(response) = value.result else {
            Issue.record("Expected refusal followed by a response disposition")
            return
        }
        #expect(phase.effectiveRequest == nil)
        #expect(response.head.value.head.status == .found)
        #expect(response.head.after.milliseconds == .observed(7))
        #expect(phase.after.milliseconds == .observed(2))
        #expect(disposition.after.milliseconds == .observed(3))
        let body = try #require(response.body)
        #expect(body.content == .bytes(Array("redirect".utf8)))
        #expect(try disposition.continuation(for: .allow) == .deliverBody(body))
        #expect(throws: HTTPResponseDispositionError.incompatibleDecision) {
            try disposition.continuation(for: .cancel)
        }
    }

    @Test
    func `follow and unanswered branches expose no redirect body or synthetic completion`() throws {
        let values = try JSONDecoder().decode([Interaction].self, from: fixture())
        for index in [0, 2, 3, 4] {
            #expect(values[index].result.responseBody == nil)
        }
        let open = try redirect(values[2].result)
        #expect(open.outcome == .openAtRecordingHorizon)
        #expect(open.effectiveRequest == nil)
        #expect(try object(open.outcome).keys.sorted() == ["kind"])
        for decision in try [HTTPRedirectDecision.refuse, .follow(request("/next"))] {
            #expect(throws: HTTPRedirectSelectionError.decisionBeyondRecordingHorizon) {
                try open.continuation(for: decision, requestsMatch: ==)
            }
        }
        let followed = try redirect(values[3].result)
        #expect(followed.outcome == .followProposed(.openAtRecordingHorizon))
        let failed = try redirect(values[4].result)
        #expect(try failed.outcome == .followProposed(.failed(.init(after: delay(19), value: "timeout"))))
    }

    @Test
    func `current choices must match the sole recorded branch and effective request`() throws {
        let proposal = try request("/next")
        let modified = try request("/modified")
        let branches: [Outcome] = [
            .followProposed(.openAtRecordingHorizon), .followModified(modified, .openAtRecordingHorizon),
            .refuse(.deliverBody(.init(content: .bytes([]), conclusion: .openAtRecordingHorizon))),
        ]
        for (index, outcome) in branches.enumerated() {
            let phase = try Phase(after: delay(0), proposedRequest: proposal, outcome: outcome)
            let wrong: [HTTPRedirectDecision] = index == 0
                ? [.refuse, .follow(modified)] : index == 1
                ? [.refuse, .follow(proposal)] : [.follow(proposal), .follow(modified)]
            for decision in wrong {
                #expect(throws: HTTPRedirectSelectionError.incompatibleDecision) {
                    try phase.continuation(for: decision, requestsMatch: ==)
                }
            }
        }
    }

    @Test
    func `branch selection uses setup equivalence across body storage`() throws {
        let inline = try request("/next", method: .post, body: .bytes([1, 2]))
        let resource = try HTTPResourceCodingFixtures.resource(path: "body.bin", bytes: [1, 2])
        let external = try request("/next", method: .post, body: .resource(resource))
        let matcher = HTTPRequestMatcher()
        let lhs = try matcher.project(ValuePreparation().admitPrepared(inline))
        let rhs = try matcher.project(ValuePreparation().admitPrepared(external))
        #expect(inline != external)
        let phase = try Phase(
            after: delay(0), proposedRequest: inline, outcome: .followProposed(.openAtRecordingHorizon))
        let selected = try phase.continuation(for: .follow(external), requestsMatch: { expected, actual in
            #expect(expected == inline)
            #expect(actual == external)
            return matcher.matches(lhs, rhs)
        })
        #expect(selected == .attempt(request: inline, result: .openAtRecordingHorizon))
    }

    @Test
    func `timing bounds stop at the current decision and preserve post-decision delays`() throws {
        let result = try Result.failed(.init(after: delay(Int64.max), value: "timeout"))
        let phase = try Phase(
            after: delay(Int64.max), proposedRequest: request("/next"), outcome: .followProposed(result))
        _ = try Response(head: timed(.found), next: .redirect(phase))
        #expect(throws: HTTPLifecycleError.delayOverflow) {
            try Response(head: timed(.found, after: 1), next: .redirect(phase))
        }
        let body = try Delivery(content: .bytes([]), conclusion: .returned(.init(after: delay(Int64.max))))
        let refused = Phase(after: phase.after, proposedRequest: phase.proposedRequest,
                            outcome: .refuse(.deliverBody(body)))
        _ = try Response(head: timed(.found), next: .redirect(refused))
        for _ in 0..<2 {
            // Selection carries no invocation timestamp or time spent answering.
            let selected = try phase.continuation(for: .follow(phase.proposedRequest), requestsMatch: ==)
            #expect(selected == .attempt(request: phase.proposedRequest, result: result))
        }
        var object = try object(Response(head: timed(.found), next: .redirect(phase)))
        object["head"] = try self.object(timed(.found, after: 1))
        try expectCorrupt(Response.self, object, path: ["next"])
    }

    @Test
    func `refusal and disposition each start an independent timing anchor`() throws {
        let maximum = try delay(Int64.max)
        let failure = HTTPTimed(after: maximum, value: "canceled")
        let body = try Delivery(content: .absent, conclusion: .returned(.init(after: maximum)))
        let outcomes: [HTTPResponseDispositionOutcome<String>] = [
            .allow(body), .cancel(failure), .openAtRecordingHorizon,
        ]
        for outcome in outcomes {
            let disposition = HTTPResponseDispositionPhase(after: maximum, outcome: outcome)
            let phase = try Phase(after: maximum, proposedRequest: request("/next"),
                                  outcome: .refuse(.disposition(disposition)))
            let response = try Response(head: timed(.found), next: .redirect(phase))
            #expect(try JSONDecoder().decode(Response.self, from: canonical(response)) == response)
            #expect(response.body == disposition.body)
            #expect(try phase.continuation(for: .refuse, requestsMatch: ==) == .disposition(disposition))
            switch outcome {
            case .allow:
                #expect(try disposition.continuation(for: .allow) == .deliverBody(body))
            case .cancel:
                #expect(try disposition.continuation(for: .cancel) == .failed(failure))
            case .openAtRecordingHorizon:
                #expect(throws: HTTPResponseDispositionError.decisionBeyondRecordingHorizon) {
                    try disposition.continuation(for: .allow)
                }
            }
        }
    }

    @Test
    func `derived lengths use the effective method at each recursive request edge`() throws {
        let raw = try Response(head: .init(after: delay(0), value: HTTPResponseHead(head: HTTPResponse(
            status: .ok, headerFields: HTTPFields([.init(name: .contentLength, value: "1")])))),
        body: .init(content: .bytes([65]), conclusion: .returned(.init(after: delay(0)))))
        let derived = try HTTPContentLength.response(ValuePreparation().admitPrepared(raw), requestMethod: .get)
        for method: HTTPRequest.Method in [.get, .head, .connect] {
            let proposal = try request("/next", method: method)
            let phase = try Phase(
                after: delay(0), proposedRequest: proposal, outcome: .followProposed(.received(derived)))
            let result = try Result.received(Response(head: timed(.found), next: .redirect(phase)))
            if method == .get {
                let value = try Interaction(initialRequest: request("/start", method: .head), result: result)
                #expect(try JSONDecoder().decode(Interaction.self, from: canonical(value)) == value)
            } else {
                #expect(throws: HTTPMessageError.invalidField) {
                    try Interaction(initialRequest: request("/start"), result: result)
                }
            }
            let modified = try Phase(after: delay(0), proposedRequest: request("/next", method: .head),
                                     outcome: .followModified(request("/modified", method: method), .received(derived)))
            let node = try Result.received(Response(head: timed(.found), next: .redirect(modified)))
            if method == .get {
                _ = try Interaction(initialRequest: request("/start"), result: node)
            } else {
                #expect(throws: HTTPMessageError.invalidField) {
                    try Interaction(initialRequest: request("/start"), result: node)
                }
            }
        }
    }

    @Test
    func `refused bodies retain resources and derived length without competing content`() throws {
        let resource = try HTTPResourceCodingFixtures.resource(path: "refused.bin", bytes: [1, 2, 3])
        let body = try Delivery(content: .resource(resource), conclusion: .returned(.init(after: delay(8))))
        let proposal = try request("/next")
        let fields = HTTPFields([.init(name: .contentLength, value: "3")])
        let head = try HTTPTimed(after: delay(2), value: HTTPResponseHead(
            head: HTTPResponse(status: .found, headerFields: fields)))
        let gated = try HTTPResponseDispositionPhase(after: delay(4), outcome: .allow(body))
        for refusal: HTTPRedirectRefusal<String> in [.deliverBody(body), .disposition(gated)] {
            let phase = try Phase(after: delay(3), proposedRequest: proposal, outcome: .refuse(refusal))
            let response = try Response(head: head, next: .redirect(phase))
            let prepared = try ValuePreparation().admitPrepared(response)
            let derived = try HTTPContentLength.response(prepared, requestMethod: .get)
            #expect(derived.head.value.derivesContentLength)
            let data = try canonical(derived)
            let decoded = try HTTPResourceCodingFixtures.decoder(resources: ["refused.bin": [9, 8, 7, 6]])
                .decode(Response.self, from: data)
            #expect(decoded.head.value.head.headerFields[.contentLength] == "4")
            #expect(try decoded.body?.content == .resource(HTTPResourceCodingFixtures.resource(
                path: "refused.bin", bytes: [9, 8, 7, 6])))
            let followed = Phase(after: phase.after, proposedRequest: proposal,
                                 outcome: .followProposed(.openAtRecordingHorizon))
            #expect(throws: HTTPMessageError.invalidField) {
                try Response(head: derived.head, next: .redirect(followed))
            }
        }
    }

    @Test
    func `nested editing selects timing overrides and rejects invalid request context`() throws {
        let values = try JSONDecoder().decode([Interaction].self, from: fixture())
        let original = try canonical(values[0])
        let json = try #require(String(data: original, encoding: .utf8))
        let edited = json.replacingOccurrences(of: "\"override\" : \"4ms\"",
                                               with: "\"observed\":\"-1ms\",\"override\":\"0.004s\"")
        #expect(try canonical(JSONDecoder().decode(Interaction.self, from: Data(edited.utf8))) == original)
        let raw = try Response(head: .init(after: delay(0), value: HTTPResponseHead(head: HTTPResponse(
            status: .ok, headerFields: HTTPFields([.init(name: .contentLength, value: "0")])))),
        body: .init(content: .bytes([]), conclusion: .returned(.init(after: delay(0)))))
        let derived = try HTTPContentLength.response(ValuePreparation().admitPrepared(raw), requestMethod: .get)
        let phase = try Phase(
            after: delay(0), proposedRequest: request("/next"), outcome: .followProposed(.received(derived)))
        let value = try Interaction(initialRequest: request("/start"), result: .received(Response(
            head: timed(.found), next: .redirect(phase))))
        let encoded = try #require(String(data: canonical(value), encoding: .utf8))
        let invalid = encoded.replacingOccurrences(of: "\"method\" : \"GET\"", with: "\"method\" : \"HEAD\"")
        let invalidObject = try #require(JSONSerialization.jsonObject(with: Data(invalid.utf8)) as? [String: Any])
        try expectCorrupt(Interaction.self, invalidObject, path: [
            "result", "response", "next", "redirect", "outcome", "result", "response", "head", "value", "fields",
        ])
        var root = try object(values[0])
        var result = try #require(root["result"] as? [String: Any])
        var response = try #require(result["response"] as? [String: Any])
        var next = try #require(response["next"] as? [String: Any])
        var redirect = try #require(next["redirect"] as? [String: Any])
        redirect["outcome"] = ["kind": "secret-marker"]
        next["redirect"] = redirect
        response["next"] = next
        result["response"] = response
        root["result"] = result
        try expectCorrupt(Interaction.self, root, path: ["result", "response", "next", "redirect", "outcome", "kind"])
    }

    @Test
    func `response continuations require one explicit tag and its matching payload`() throws {
        let body = Delivery(content: .absent, conclusion: .openAtRecordingHorizon)
        let phase = try Phase(
            after: delay(0), proposedRequest: request("/next"), outcome: .openAtRecordingHorizon)
        let continuations: [HTTPAfterResponseHead<String>] = [.deliverBody(body), .redirect(phase)]
        for continuation in continuations {
            let encoded = try object(continuation)
            #expect(try decode(HTTPAfterResponseHead<String>.self, encoded) == continuation)
            try rejectEdits(HTTPAfterResponseHead<String>.self, encoded)
            var competing = encoded
            competing["body"] = try object(body)
            competing["redirect"] = try object(phase)
            #expect(throws: (any Error).self) { try decode(HTTPAfterResponseHead<String>.self, competing) }
            var wrongTag = encoded
            wrongTag["kind"] = encoded["kind"] as? String == "deliverBody" ? "redirect" : "deliverBody"
            #expect(throws: (any Error).self) { try decode(HTTPAfterResponseHead<String>.self, wrongTag) }
        }
        let response = try Response(head: timed(.found), next: .redirect(phase))
        var legacy = try object(response)
        legacy.removeValue(forKey: "next")
        for key in ["body", "redirect"] {
            legacy[key] = key == "body" ? try object(body) : try object(phase)
            #expect(throws: (any Error).self) { try decode(Response.self, legacy) }
            legacy.removeValue(forKey: key)
        }
        var unknown = try object(response)
        unknown["next"] = ["kind": "secret-marker"]
        try expectCorrupt(Response.self, unknown, path: ["next", "kind"])
    }

    @Test
    func `every redirect boundary rejects missing null unknown and conflicting fields`() throws {
        let values = try JSONDecoder().decode([Interaction].self, from: fixture())
        for value in values {
            let phase = try redirect(value.result)
            try rejectEdits(Phase.self, object(phase))
            try rejectEdits(Outcome.self, object(phase.outcome))
            if case let .refuse(refusal) = phase.outcome {
                try rejectEdits(HTTPRedirectRefusal<String>.self, object(refusal))
            }
            guard case let .received(response) = value.result else { continue }
            var competing = try object(response)
            competing["body"] = try object(Delivery(content: .absent, conclusion: .openAtRecordingHorizon))
            #expect(throws: (any Error).self) { try decode(Response.self, competing) }
        }
        let phase = try redirect(values[0].result)
        guard case let .followProposed(next) = phase.outcome else {
            Issue.record("Expected nested modified redirect fixture")
            return
        }
        let modified = try redirect(next)
        try rejectEdits(Phase.self, object(modified))
        try rejectEdits(Outcome.self, object(modified.outcome))
        for key in ["request", "body", "next", "failure", "decisionLatency", "version"] {
            var bad = try object(phase.outcome)
            bad[key] = true
            #expect(throws: (any Error).self) { try decode(Outcome.self, bad) }
        }
        let invalid: [[String: Any]] = try [
            ["kind": "followProposed", "result": ["kind": "returned"]],
            ["kind": "refuse", "body": ["content": ["kind": "absent"], "conclusion": ["kind": "open"]]],
            ["kind": "refuse", "next": ["kind": "redirect", "redirect": object(phase)]],
            ["kind": "refuse", "next": ["kind": "authenticate"]],
            ["kind": "open", "result": ["kind": "open"]],
            ["kind": "followModified", "result": ["kind": "open"]],
        ]
        for value in invalid {
            #expect(throws: (any Error).self) { try decode(Outcome.self, value) }
        }
        try expectCorrupt(Outcome.self, ["kind": "refuse", "next": ["kind": "secret-marker"]], path: ["next", "kind"])
        try expectCorrupt(Outcome.self, ["kind": "secret-marker"], path: ["kind"])
        var negative = try object(phase)
        negative["after"] = "-1ms"
        try expectCorrupt(Phase.self, negative, path: ["after"])
    }

    private func request(_ path: String, method: HTTPRequest.Method = .get,
                         body: HTTPRequestBody = .absent) throws -> HTTPRequestMessage
    {
        try HTTPRequestMessage(head: HTTPRequest(
            method: method, scheme: "https", authority: "example.invalid", path: path), body: body)
    }

    private func delay(_ value: Int64) throws -> HTTPDelay {
        try HTTPDelay(milliseconds: .observed(value))
    }

    private func timed(_ status: HTTPResponse.Status, after: Int64 = 0) throws -> HTTPTimed<HTTPResponseHead> {
        try HTTPTimed(after: delay(after), value: HTTPResponseHead(head: HTTPResponse(status: status)))
    }

    private func received(status: HTTPResponse.Status, after: Int64, body: Delivery) throws -> Result {
        try .received(Response(head: timed(status, after: after), body: body))
    }

    private func redirect(_ result: Result) throws -> Phase {
        guard case let .received(response) = result, case let .redirect(phase) = response.next else {
            throw TestError.expectedRedirect
        }
        return phase
    }

    private enum TestError: Error { case expectedRedirect }

    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "redirects", withExtension: "json", subdirectory: "Fixtures"))
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
            var missing = value
            missing.removeValue(forKey: key)
            #expect(throws: (any Error).self) { try decode(type, missing) }
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
            Issue.record("Expected a structural decoding failure")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == path)
            #expect(!context.debugDescription.contains("secret-marker"))
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
