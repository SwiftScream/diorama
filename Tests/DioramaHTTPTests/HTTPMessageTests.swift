import DioramaHTTP
import Foundation
import HTTPTypes
import Testing

struct HTTPMessageTests {
    @Test
    func `request golden preserves target fields and exact bytes`() throws {
        let token = try #require(HTTPField.Name("X-Token"))
        var fields = HTTPFields()
        fields.append(HTTPField(name: token, value: "one"))
        fields.append(HTTPField(name: token, value: "two"))
        let message = try HTTPRequestMessage(
            head: HTTPRequest(method: .post, scheme: "https", authority: "example.invalid", path: "/a?b=%2F",
                              headerFields: fields),
            body: .bytes([0, 128, 255]))
        let data = try fixture("request")
        #expect(try JSONDecoder().decode(HTTPRequestMessage.self, from: data) == message)
        #expect(try canonical(message) == data)
        #expect(message.head.headerFields.map(\.value) == ["one", "two"])
    }

    @Test
    func `response golden preserves repeated cookies and custom status`() throws {
        let data = try fixture("response")
        let response = try JSONDecoder().decode(HTTPResponseHead.self, from: data)
        #expect(response.head.status.code == 299)
        #expect(response.head.status.reasonPhrase == "Custom")
        #expect(response.head.headerFields.map(\.value) == ["a=1", "b=2"])
        #expect(try canonical(response) == data)
    }

    @Test
    func `absent empty resource and unavailable are distinct`() throws {
        let resource = try HTTPBodyResource(path: "bodies/reply.bin")
        let bodies: [HTTPResponseBody] = [.absent, .bytes([]), .bytes([0, 255]), .resource(resource), .unavailable]
        #expect(Set(bodies).count == 5)
        #expect(try canonical(bodies) == fixture("bodies"))
        #expect(try JSONDecoder().decode([HTTPResponseBody].self, from: fixture("bodies")) == bodies)
        for body in bodies {
            #expect(try JSONDecoder().decode(HTTPResponseBody.self, from: canonical(body)) == body)
        }
        let head = HTTPRequest(method: .get, scheme: nil, authority: "host:443", path: nil)
        for body: HTTPRequestBody in [.absent, .bytes([]), .bytes([0, 255]), .resource(resource)] {
            let request = try HTTPRequestMessage(head: head, body: body)
            #expect(try JSONDecoder().decode(HTTPRequestMessage.self, from: canonical(request)) == request)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(HTTPRequestBody.self, from: canonical(HTTPResponseBody.unavailable))
        }
    }

    @Test
    func `field bytes and case survive without dependency codable`() throws {
        let name = try #require(HTTPField.Name("X-Raw"))
        var fields = HTTPFields()
        fields.append(HTTPField(name: name, value: [0x80, 0xFF]))
        fields.append(HTTPField(name: name, value: "café"))
        let message = HTTPResponseHead(head: HTTPResponse(status: .ok, headerFields: fields))
        let decoded = try JSONDecoder().decode(HTTPResponseHead.self, from: canonical(message))
        #expect(decoded.head.headerFields.map(\.name.rawName) == ["X-Raw", "X-Raw"])
        let values = decoded.head.headerFields.map { $0.withUnsafeBytesOfValue { Array($0) } }
        #expect(values == [[0x80, 0xFF], Array("café".utf8)])
    }

    @Test(arguments: [
        "", "/absolute", "a//b", "../escape", "a/./b", "a/../b", "a/", "a\\b", "C:drive", "a\n",
    ])
    func `invalid resource paths are rejected`(_ path: String) {
        #expect(throws: HTTPMessageError.invalidResource) { try HTTPBodyResource(path: path) }
    }

    @Test
    func `inline content preserves every byte and all padding lengths`() throws {
        for bytes in [Array(UInt8.min...UInt8.max), [0], [0, 255], [0, 128, 255]] {
            let body = HTTPResponseBody.bytes(bytes)
            let encoded = try canonical(body)
            #expect(try JSONDecoder().decode(HTTPResponseBody.self, from: encoded) == body)
            #expect(try JSONDecoder().decode(HTTPRequestBody.self, from: encoded) == .bytes(bytes))
        }
    }

    @Test
    func `UTF8 text goldens preserve HTML JSON and exact spelling`() throws {
        let strings = [
            "", "<html>\r\n<body title=\"café\">Hello</body>\r\n</html>\n",
            #"{ "amount":1.00, "amount":2, "escaped":"\u0061" }"#,
            "café", "cafe\u{301}", "😀", "\u{FEFF}body", "a\tb\nc\rd",
        ]
        let bodies = strings.map { HTTPResponseBody.bytes(Array($0.utf8)) }
        #expect(try canonical(bodies) == fixture("text-bodies"))
        #expect(try JSONDecoder().decode([HTTPResponseBody].self, from: fixture("text-bodies")) == bodies)
        for (text, body) in zip(strings, bodies) {
            let encoded = try canonical(body)
            let object = try JSONDecoder().decode([String: String].self, from: encoded)
            #expect(object == ["kind": "bytes", "text": text])
            #expect(try JSONDecoder().decode(HTTPRequestBody.self, from: encoded) == .bytes(Array(text.utf8)))
        }
    }

    @Test(arguments: [[UInt8(0xFF)], [0xC3, 0x28], [0xE2, 0x82], [0xC0, 0xAF], [0xED, 0xA0, 0x80]])
    func `invalid UTF8 and partial sequences remain base64`(_ bytes: [UInt8]) throws {
        let encoded = try canonical(HTTPResponseBody.bytes(bytes))
        let object = try JSONDecoder().decode([String: String].self, from: encoded)
        #expect(object == ["kind": "bytes", "base64": Data(bytes).base64EncodedString()])
        #expect(try JSONDecoder().decode(HTTPResponseBody.self, from: encoded) == .bytes(bytes))
    }

    @Test
    func `base64 input canonicalizes UTF8 content to text without changing bytes`() throws {
        for bytes in [[], Array("<html>hello</html>\n".utf8), [0, 9, 13, 10]] {
            let encoded = try JSONSerialization.data(withJSONObject: [
                "kind": "bytes", "base64": Data(bytes).base64EncodedString(),
            ])
            let body = try JSONDecoder().decode(HTTPResponseBody.self, from: encoded)
            #expect(body == .bytes(bytes))
            let object = try JSONDecoder().decode([String: String].self, from: canonical(body))
            #expect(object["text"] != nil)
            #expect(object["base64"] == nil)
        }
    }

    @Test(arguments: [
        #"{"kind":"future"}"#, #"{"kind":"absent","base64":""}"#,
        #"{"kind":"bytes"}"#, #"{"kind":"bytes","base64":[]}"#,
        #"{"kind":"bytes","base64":"","resource":"a"}"#,
        #"{"kind":"resource","resource":"../a"}"#, #"{"kind":"absent","extra":1}"#,
        #"{"kind":"absent","base64":null}"#, #"{"kind":"bytes","bytes":[0,255]}"#,
        #"{"kind":"bytes","text":"a","base64":"YQ=="}"#,
        #"{"kind":"bytes","text":"a","resource":"a.txt"}"#,
        #"{"kind":"absent","text":""}"#, #"{"kind":"unavailable","text":""}"#,
        #"{"kind":"bytes","text":null}"#, #"{"kind":"bytes","text":123}"#,
        #"{"kind":"bytes","text":{"a":1}}"#,
    ])
    func `malformed body is rejected`(_ json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(HTTPResponseBody.self, from: Data(json.utf8)) }
    }

    @Test(arguments: ["!", "AP8", "AP8===", "AP8=\n", "AP 8=", "AP_=", "AB==", "AAB=", "===="])
    func `malformed or noncanonical base64 is rejected`(_ text: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["kind": "bytes", "base64": text])
        #expect(throws: HTTPMessageError.invalidBody) { try JSONDecoder().decode(HTTPResponseBody.self, from: data) }
        #expect(throws: HTTPMessageError.invalidBody) { try JSONDecoder().decode(HTTPRequestBody.self, from: data) }
    }

    @Test(arguments: [
        #"{"status":1000,"reasonPhrase":"","fields":[]}"#,
        #"{"status":-1,"reasonPhrase":"","fields":[]}"#,
        #"{"status":200,"reasonPhrase":"bad\nphrase","fields":[]}"#,
        #"{"status":200,"reasonPhrase":"","fields":[],"version":"HTTP/1.1"}"#,
        #"{"status":200,"reasonPhrase":"","fields":[{"name":":status","value":"200"}]}"#,
        #"{"status":200,"reasonPhrase":"","fields":[{"name":"Bad Name","value":"a"}]}"#,
        #"{"status":200,"reasonPhrase":"","fields":[{"name":"x","value":"a\rb"}]}"#,
        #"{"status":200,"reasonPhrase":"","fields":[{"name":"x","value":"😀"}]}"#,
        #"{"status":200,"reasonPhrase":"","fields":[{"name":"x","value":"a","typo":1}]}"#,
    ])
    func `malformed response is rejected`(_ json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(HTTPResponseHead.self, from: Data(json.utf8)) }
    }

    @Test
    func `malformed requests are rejected and custom methods survive`() throws {
        let text = try #require(String(data: fixture("request"), encoding: .utf8))
        for invalid in [
            text.replacingOccurrences(of: "POST", with: "BAD METHOD"),
            text.replacingOccurrences(of: "https", with: "bad\\nscheme"),
            text.replacingOccurrences(
                of: #""method" : "POST""#, with: #""method" : "POST", "typo": true"#),
        ] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(HTTPRequestMessage.self, from: Data(invalid.utf8))
            }
        }
        let method = try #require(HTTPRequest.Method("CUSTOM"))
        let request = try HTTPRequestMessage(head: HTTPRequest(method: method, scheme: nil, authority: nil, path: "*"))
        #expect(try JSONDecoder().decode(HTTPRequestMessage.self, from: canonical(request)).head.method == method)
        var extended = request.head
        extended.extendedConnectProtocol = "websocket"
        #expect(throws: HTTPMessageError.unsupportedRequest) { try HTTPRequestMessage(head: extended) }
    }

    private func canonical(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(10)
        return data
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}
