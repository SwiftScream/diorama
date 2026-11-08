import DioramaCore
import DioramaHTTP
import Foundation
import HTTPTypes
import Testing

struct HTTPLifecycleTests {
    private enum Failure: String, Codable, Sendable {
        case timeout, connectionLost
    }

    private typealias Interaction = HTTPInteraction<Failure>

    @Test
    func `tagged lifecycle golden preserves each strict leaf and exact content`() throws {
        let expected = try examples()
        let data = try fixture()
        let decoded = try JSONDecoder().decode([Interaction].self, from: data)
        #expect(decoded == expected)
        #expect(try canonical(decoded) == data)
        #expect(try canonical(expected) == data)
    }

    @Test
    func `HTTP error statuses return while partial transport failure stays distinct`() throws {
        let values = try examples()
        guard case let .received(returned) = values[0].result,
              case let .returned(completion) = returned.body.conclusion,
              case let .failed(beforeHead) = values[1].result,
              case let .received(failed) = values[3].result,
              case let .failed(afterHead) = failed.body.conclusion
        else {
            Issue.record("Expected distinct returned, pre-head failure, and body failure branches")
            return
        }
        #expect(returned.head.value.head.status.code == 404)
        #expect(returned.body.content == .bytes(Array("ok".utf8)))
        #expect(completion.after.milliseconds == .observed(3))
        #expect(beforeHead.value == .timeout)
        #expect(beforeHead.after.milliseconds == .observed(25))
        #expect(failed.head.value.head.status.code == 503)
        #expect(failed.body.content == .bytes([0, 255]))
        #expect(afterHead.value == .connectionLost)

        let serverError = try received(
            status: .serviceUnavailable, content: .absent, conclusion: .returned(completed()))
        guard case .received = serverError.result else {
            Issue.record("HTTP 503 must be constructible as successful message delivery")
            return
        }
        #expect(try JSONDecoder().decode(Interaction.self, from: canonical(serverError)) == serverError)
    }

    @Test
    func `open before and after a head never acquires synthetic completion`() throws {
        let values = try examples()
        #expect(values[2].result == .openAtRecordingHorizon)
        guard case let .received(response) = values[4].result else {
            Issue.record("Expected response with an open prefix")
            return
        }
        #expect(response.body.conclusion == .openAtRecordingHorizon)
        #expect(response.body.content == .bytes([0xE2, 0x82]))
        let openRoot = try object(values[2])
        let rootResult = try #require(openRoot["result"] as? [String: Any])
        #expect(rootResult.keys.sorted() == ["kind"])
        let openBody = try object(response.body)
        let conclusion = try #require(openBody["conclusion"] as? [String: Any])
        #expect(conclusion.keys.sorted() == ["kind"])
        #expect(openBody.keys.sorted() == ["conclusion", "content"])
    }

    @Test
    func `all body meanings survive failed open and returned leaves without copies`() throws {
        let contents: [HTTPResponseBody] = try [
            .absent, .bytes([]), .bytes([255]),
            .resource(HTTPBodyResource(path: "bodies/prefix.bin")), .unavailable,
        ]
        let conclusions: [HTTPBodyConclusion<Failure>] = try [
            .returned(completed()), .failed(timed(.connectionLost)), .openAtRecordingHorizon,
        ]
        for content in contents {
            for conclusion in conclusions {
                let value = try received(status: .ok, content: content, conclusion: conclusion)
                let data = try canonical(value)
                #expect(try JSONDecoder().decode(Interaction.self, from: data) == value)
                let root = try object(value)
                #expect(root.keys.sorted() == ["initialRequest", "result"])
                let result = try #require(root["result"] as? [String: Any])
                let response = try #require(result["response"] as? [String: Any])
                #expect(response.keys.sorted() == ["body", "head"])
                let body = try #require(response["body"] as? [String: Any])
                #expect(body.keys.sorted() == ["conclusion", "content"])
            }
        }
        #expect(contents[0] != contents[1])
        #expect(contents[0] != contents[4])
        #expect(contents[1] != contents[4])
    }

    @Test
    func `trailers preserve ordered repeated fields and original byte spelling`() throws {
        let values = try JSONDecoder().decode([Interaction].self, from: fixture())
        guard case let .received(response) = values[0].result,
              case let .returned(completion) = response.body.conclusion
        else {
            Issue.record("Expected completed response")
            return
        }
        let trailers = try #require(completion.trailers)
        #expect(trailers.after.milliseconds == .observed(2))
        #expect(trailers.fields.map(\.name.rawName) == ["X-End", "X-End", "X-Raw"])
        #expect(trailers.fields.map { $0.withUnsafeBytesOfValue { Array($0) } }
            == [Array("first".utf8), Array("second".utf8), [0x80, 0xFF]])
        let encoded = try object(trailers)
        let fields = try #require(encoded["fields"] as? [[String: String]])
        #expect(fields[0] == ["name": "X-End", "value": "first"])
        #expect(fields[2] == ["name": "X-Raw", "value": "\u{80}ÿ"])
        #expect(try completed().trailers == nil)
        let empty = try HTTPBodyCompletion(
            after: delay(0), trailers: HTTPTrailers(after: delay(0), fields: HTTPFields()))
        #expect(try JSONDecoder().decode(HTTPBodyCompletion.self, from: canonical(empty)) == empty)
    }

    @Test
    func `builders reject negative effective delays and accept the full scalar range`() throws {
        #expect(throws: HTTPLifecycleError.negativeDelay) { try HTTPDelay(milliseconds: .observed(-1)) }
        #expect(throws: HTTPLifecycleError.negativeDelay) { try HTTPDelay(milliseconds: .override(Int64.min)) }
        for value: Int64 in [0, 1, 1000, Int64.max] {
            for authored in [false, true] {
                let delay = try HTTPDelay(milliseconds: authored ? .override(value) : .observed(value))
                #expect(delay.milliseconds.value == value)
                #expect(delay.milliseconds.isOverride == authored)
                #expect(try JSONDecoder().decode(HTTPDelay.self, from: canonical(delay)) == delay)
            }
        }
    }

    @Test
    func `duration editing normalizes one effective override without keeping observations`() throws {
        let delay = try decode(HTTPDelay.self, #"{"observed":"9s","override":"1.250s"}"#)
        #expect(delay.milliseconds == .override(1250))
        let canonicalText = try #require(String(data: canonical(delay), encoding: .utf8))
        #expect(canonicalText == "{\n  \"override\" : \"1250ms\"\n}\n")
        #expect(try decode(HTTPDelay.self, #"{"observed":"1.000s"}"#).milliseconds == .observed(1000))
        #expect(try decode(HTTPDelay.self, #""0ms""#).milliseconds == .observed(0))
        let response = try received(
            status: .ok, content: .bytes([]),
            conclusion: .failed(HTTPTimed(after: delay, value: Failure.timeout)))
        #expect(try JSONDecoder().decode(Interaction.self, from: canonical(response)) == response)
    }

    @Test(arguments: [
        #""-1ms""#, #""0.0001s""#, #""1.5ms""#, #""9223372036854775808ms""#,
        #""NaNs""#, #""infs""#, #"1"#, #"null"#, #"{}"#,
        #"{"override":"-1ms"}"#, #"{"observed":"1s","override":null}"#,
        #"{"observed":"1s","override":"-1ms"}"#, #"{"override":"1s","extra":true}"#,
    ])
    func `invalid persisted delays never construct runtime values`(_ json: String) {
        #expect(throws: (any Error).self) { try decode(HTTPDelay.self, json) }
    }

    @Test(arguments: [
        #"{}"#, #"null"#, #"{"kind":"returned"}"#, #"{"kind":"future"}"#,
        #"{"kind":"received"}"#, #"{"kind":"received","response":null}"#,
        #"{"kind":"failed"}"#, #"{"kind":"failed","failure":null}"#,
        #"{"kind":"open","failure":null}"#, #"{"kind":"open","response":{}}"#,
        #"{"kind":"open","conclusion":"returned"}"#,
    ])
    func `invalid attempt leaves are rejected`(_ json: String) {
        #expect(throws: (any Error).self) { try decode(HTTPAttemptResult<Failure>.self, json) }
    }

    @Test(arguments: [
        #"{}"#, #"null"#, #"{"kind":"future"}"#, #"{"kind":"returned"}"#,
        #"{"kind":"returned","completion":null}"#, #"{"kind":"failed"}"#,
        #"{"kind":"failed","failure":null}"#, #"{"kind":"open","completion":{}}"#,
        #"{"kind":"open","trailers":[]}"#,
        #"{"kind":"returned","completion":{"after":"0ms"},"failure":{}}"#,
        #"{"kind":"failed","failure":{"after":"0ms","value":"timeout"},"trailers":[]}"#,
    ])
    func `conflicting body leaves and trailers outside completion are rejected`(_ json: String) {
        #expect(throws: (any Error).self) { try decode(HTTPBodyConclusion<Failure>.self, json) }
    }

    @Test
    func `every required field null and unknown field is checked at its own boundary`() throws {
        let root = try object(examples()[0])
        try rejectFieldEdits(Interaction.self, root)
        let result = try #require(root["result"] as? [String: Any])
        try rejectFieldEdits(HTTPAttemptResult<Failure>.self, result)
        let response = try #require(result["response"] as? [String: Any])
        try rejectFieldEdits(HTTPResponseNode<Failure>.self, response)
        let head = try #require(response["head"] as? [String: Any])
        try rejectFieldEdits(HTTPTimed<HTTPResponseHead>.self, head)
        let body = try #require(response["body"] as? [String: Any])
        try rejectFieldEdits(HTTPBodyDelivery<Failure>.self, body)
        let conclusion = try #require(body["conclusion"] as? [String: Any])
        try rejectFieldEdits(HTTPBodyConclusion<Failure>.self, conclusion)
        let completion = try #require(conclusion["completion"] as? [String: Any])
        try rejectFieldEdits(HTTPBodyCompletion.self, completion, optional: ["trailers"])
        let trailers = try #require(completion["trailers"] as? [String: Any])
        try rejectFieldEdits(HTTPTrailers.self, trailers)
        let failure = try object(timed(Failure.timeout))
        try rejectFieldEdits(HTTPTimed<Failure>.self, failure)
        let failedResult: HTTPAttemptResult<Failure> = try .failed(timed(.timeout))
        try rejectFieldEdits(HTTPAttemptResult<Failure>.self, object(failedResult))
    }

    @Test
    func `nested delay and tag errors identify their exact coding path without values`() throws {
        let response = try received(status: .ok, content: .absent, conclusion: .returned(completed()))
        let data = try canonical(response)
        let json = try #require(String(data: data, encoding: .utf8))
        let badDelay = json.replacingOccurrences(of: "\"after\" : \"10ms\"", with: "\"after\" : \"-1ms\"")
        do {
            _ = try decode(Interaction.self, badDelay)
            Issue.record("Expected invalid nested delay")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == ["result", "response", "head", "after"])
            #expect(!context.debugDescription.contains("-1ms"))
        }
        let badTag = json.replacingOccurrences(of: "\"kind\" : \"returned\"", with: "\"kind\" : \"secret-tag\"")
        do {
            _ = try decode(Interaction.self, badTag)
            Issue.record("Expected incompatible nested tag")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == ["result", "response", "body", "conclusion", "kind"])
            #expect(!context.debugDescription.contains("secret-tag"))
        }
    }

    @Test(arguments: [
        #"{"after":"0ms","fields":[{"name":":status","value":"ok"}]}"#,
        #"{"after":"0ms","fields":[{"name":"X-End","value":"line\nbreak"}]}"#,
        #"{"after":"0ms","fields":[{"name":"X-End","value":"😀"}]}"#,
        #"{"after":"0ms","fields":[{"name":"X-End","value":"ok","extra":true}]}"#,
    ])
    func `trailers share strict regular field validation`(_ json: String) {
        #expect(throws: (any Error).self) { try decode(HTTPTrailers.self, json) }
    }

    private func examples() throws -> [Interaction] {
        let end = try #require(HTTPField.Name("X-End"))
        let raw = try #require(HTTPField.Name("X-Raw"))
        let trailers = try HTTPTrailers(after: delay(2), fields: HTTPFields([
            HTTPField(name: end, value: "first"), HTTPField(name: end, value: "second"),
            HTTPField(name: raw, value: [0x80, 0xFF]),
        ]))
        return try [
            received(status: .notFound, content: .bytes(Array("ok".utf8)),
                     conclusion: .returned(HTTPBodyCompletion(after: delay(3), trailers: trailers))),
            Interaction(initialRequest: request(), result: .failed(timed(.timeout, after: 25))),
            Interaction(initialRequest: request(), result: .openAtRecordingHorizon),
            received(status: .serviceUnavailable, content: .bytes([0, 255]),
                     conclusion: .failed(timed(.connectionLost, after: 20))),
            received(status: .ok, content: .bytes([0xE2, 0x82]), conclusion: .openAtRecordingHorizon),
            received(status: .noContent, content: .absent, conclusion: .returned(completed())),
            received(status: .ok, content: .bytes([]), conclusion: .returned(completed())),
            received(status: .found, content: .unavailable, conclusion: .openAtRecordingHorizon),
            received(status: .ok, content: .resource(HTTPBodyResource(path: "bodies/reply.bin")),
                     conclusion: .returned(completed())),
        ]
    }

    private func request() throws -> HTTPRequestMessage {
        try HTTPRequestMessage(
            head: HTTPRequest(method: .get, scheme: "https", authority: "example.invalid", path: "/"))
    }

    private func delay(_ milliseconds: Int64) throws -> HTTPDelay {
        try HTTPDelay(milliseconds: .observed(milliseconds))
    }

    private func timed<Value>(_ value: Value, after milliseconds: Int64 = 0) throws -> HTTPTimed<Value> {
        try HTTPTimed(after: delay(milliseconds), value: value)
    }

    private func completed() throws -> HTTPBodyCompletion {
        try HTTPBodyCompletion(after: delay(0))
    }

    private func received(status: HTTPResponse.Status, content: HTTPResponseBody,
                          conclusion: HTTPBodyConclusion<Failure>) throws -> Interaction
    {
        try Interaction(initialRequest: request(), result: .received(HTTPResponseNode(
            head: timed(HTTPResponseHead(head: HTTPResponse(status: status)), after: 10),
            body: HTTPBodyDelivery(content: content, conclusion: conclusion))))
    }

    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "lifecycle", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func canonical(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data([10])
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: canonical(value)) as? [String: Any])
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func rejectFieldEdits(
        _ type: (some Decodable).Type, _ object: [String: Any], optional: Set<String> = []) throws
    {
        for key in object.keys.sorted() {
            var missing = object
            missing.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: missing)
            if optional.contains(key) {
                _ = try JSONDecoder().decode(type, from: data)
            } else {
                #expect(throws: (any Error).self) { try JSONDecoder().decode(type, from: data) }
            }
            var nulled = object
            nulled[key] = NSNull()
            let nullData = try JSONSerialization.data(withJSONObject: nulled)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(type, from: nullData) }
        }
        var extra = object
        extra["unknown"] = true
        let extraData = try JSONSerialization.data(withJSONObject: extra)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(type, from: extraData) }
    }
}
