import DioramaCore
import DioramaHTTP
import DioramaPersistence
import DioramaURLSession
import Foundation
import HTTPTypes
import Testing

@Suite(.timeLimit(.minutes(1)))
struct URLSessionFailureCodingTests {
    @Test
    func `canonical failure components retain nested metadata and native URL types`() throws {
        let url = try #require(Bundle.module.url(
            forResource: "failures", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try Data(contentsOf: url)
        let values = try JSONDecoder().decode([URLSessionFailure].self, from: fixture)
        #expect(values.count == 2)
        #expect(values[0].domain == NSURLErrorDomain)
        #expect(values[0].code == -1009)
        let first = values[0].makeError() as NSError
        #expect((first.userInfo["url"] as? URL)?.absoluteString == "https://example.invalid/exact?x=%2f&x=%2F")
        let nested = try #require(first.userInfo["nested"] as? [String: [NSNumber]])
        #expect(nested["items"]?.first?.int64Value == Int64.max)
        #expect(nested["items"]?.last?.boolValue == true)
        #expect(values[1].domain == "ExampleError")
        #expect(values[1].code == 987_654)
        #expect((values[1].makeError() as NSError).userInfo["custom"] as? String == "retained")
        #expect(try canonical(values) == fixture)
        #expect(try canonical(JSONDecoder().decode([URLSessionFailure].self, from: canonical(values))) == fixture)
    }

    @Test
    func `pre-response and partial-body failures use the same generic HTTP lifecycle`() throws {
        let failure = try URLSessionFailure(domain: NSURLErrorDomain, code: -1005)
        let request = try HTTPRequestMessage(head: HTTPRequest(
            method: .get, scheme: "https", authority: "example.invalid", path: "/"))
        let timed = try HTTPTimed(after: HTTPDelay(milliseconds: .observed(5)), value: failure)
        let before = try HTTPInteraction(initialRequest: request, result: .failed(timed))
        let response = try HTTPResponseNode(
            head: HTTPTimed(after: HTTPDelay(milliseconds: .observed(2)),
                            value: HTTPResponseHead(head: HTTPResponse(status: .serviceUnavailable))),
            body: HTTPBodyDelivery(content: .bytes([0, 255]), conclusion: .failed(timed)))
        let after = try HTTPInteraction(initialRequest: request, result: .received(response))
        for value in [before, after] {
            let data = try canonical(value)
            #expect(try JSONDecoder().decode(HTTPInteraction<URLSessionFailure>.self, from: data) == value)
        }
        // A received status remains a response; only the explicit failure leaf fails transport.
        #expect(response.head.value.head.status == .serviceUnavailable)
        #expect(response.body?.content == .bytes([0, 255]))
    }

    @Test
    func `domain byte limits are exact and codes are not rounded`() throws {
        let domain = String(repeating: "d", count: 256)
        let value = try URLSessionFailure(domain: domain, code: Int.max)
        #expect(try JSONDecoder().decode(URLSessionFailure.self, from: canonical(value)) == value)
        #expect(throws: URLSessionFailureError.invalidSnapshot) {
            try URLSessionFailure(domain: domain + "a", code: 0)
        }
    }

    @Test
    func `strict component and snapshot keys reject missing null and unknown fields`() throws {
        let value = try URLSessionFailure(domain: NSURLErrorDomain, code: -1001)
        let root = try object(value)
        for key in ["version", "error"] {
            var missing = root
            missing.removeValue(forKey: key)
            #expect(throws: (any Error).self) { try decode(missing) }
            var nulled = root
            nulled[key] = NSNull()
            #expect(throws: (any Error).self) { try decode(nulled) }
        }
        for key in ["name", "failingURL", "unknown"] {
            var extra = root
            extra[key] = "unexpected"
            #expect(throws: (any Error).self) { try decode(extra) }
        }
        for key in ["domain", "code", "userInfo"] {
            let error = try #require(root["error"] as? [String: Any])
            var missing = error
            missing.removeValue(forKey: key)
            var input = root
            input["error"] = missing
            #expect(throws: (any Error).self) { try decode(input) }
            var nulled = error
            nulled[key] = NSNull()
            input["error"] = nulled
            #expect(throws: (any Error).self) { try decode(input) }
        }
        var extra = try #require(root["error"] as? [String: Any])
        extra["unknown"] = true
        var input = root
        input["error"] = extra
        #expect(throws: (any Error).self) { try decode(input) }
        for version in [0, 2, -1] {
            input = root
            input["version"] = version
            do {
                _ = try decode(input)
                Issue.record("Expected unsupported failure version")
            } catch let DecodingError.dataCorrupted(context) {
                #expect(context.codingPath.map(\.stringValue) == ["version"])
                #expect(context.underlyingError as? URLSessionFailureError == .unsupportedVersion)
            }
        }
    }

    @Test(arguments: [
        ("url", "https://example.invalid/bad path"),
        ("string", String(repeating: "s", count: 4097)),
    ])
    func `invalid snapshot values identify the metadata field`(_ type: String, value: String) throws {
        let input: [String: Any] = [
            "version": 1, "error": [
                "domain": "CustomError", "code": 42, "userInfo": ["private-key": ["type": type, "value": value]],
            ],
        ]
        do {
            _ = try decode(input)
            Issue.record("Expected invalid error metadata")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == ["error", "userInfo"])
        }
    }

    @Test
    func `edited metadata rejects malformed tags and shared bound violations`() throws {
        let invalid: [[String: Any]] = [
            ["type": "integer", "value": 1, "unknown": true],
            ["type": "unknown", "value": 1],
            ["type": "integer"],
            ["type": "integer", "value": NSNull()],
            ["type": "integer", "value": "1"],
            ["type": "integer", "value": 1.5],
            ["type": "url", "value": "https://example.invalid/bad path"],
            ["type": "string", "value": String(repeating: "s", count: 4097)],
            ["type": "array", "value": Array(repeating: ["type": "integer", "value": 1], count: 33)],
        ]
        for tag in invalid {
            let input: [String: Any] = [
                "version": 1, "error": ["domain": "CustomError", "code": 42, "userInfo": ["custom": tag]],
            ]
            #expect(throws: (any Error).self) { try decode(input) }
        }
    }

    private func canonical(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data([10])
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: canonical(value)) as? [String: Any])
    }

    private func decode(_ value: [String: Any]) throws -> URLSessionFailure {
        try JSONDecoder().decode(URLSessionFailure.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
