import DioramaCore
import DioramaHTTP
import Foundation
import HTTPTypes
import Testing

struct HTTPContentLengthTests {
    private typealias Response = HTTPResponseNode<String>

    @Test
    func `recording requires prepared complete unambiguous matching bytes`() throws {
        for value in ["3", "003", "2", "+3", "3, 3", "18446744073709551616", ""] {
            let request = try request(fields: HTTPFields([HTTPField(name: .contentLength, value: value)]))
            let selected = try HTTPContentLength.request(ValuePreparation().admitPrepared(request))
            #expect(selected.derivesContentLength == ["3", "003"].contains(value))
        }
        for name: HTTPField.Name in [.contentEncoding, .transferEncoding, .contentRange, .contentLength] {
            let fields = HTTPFields([.init(name: .contentLength, value: "3"), .init(name: name, value: "3")])
            #expect(try !select(request(fields: fields)).derivesContentLength)
        }
        for method: HTTPRequest.Method in [.head, .connect] {
            #expect(try !select(request(method: method)).derivesContentLength)
        }
        #expect(try !select(request(body: .absent)).derivesContentLength)
        #expect(try select(request(body: .bytes([]), length: "0")).derivesContentLength)
        #expect(try !select(request(fields: HTTPFields())).derivesContentLength)
    }

    @Test
    func `authored literals survive reencoding while explicit derived edits resolve byte counts`() throws {
        let literal = try request()
        let encoded = try JSONEncoder().encode(literal)
        let literalJSON = try #require(String(data: encoded, encoding: .utf8))
        #expect(!literalJSON.contains("derivedFrom"))
        #expect(try JSONDecoder().decode(HTTPRequestMessage.self, from: encoded) == literal)
        let selected = try select(literal)
        let data = try JSONEncoder().encode(selected)
        #expect(try #require(String(data: data, encoding: .utf8)).contains(#""value":{"derivedFrom":"bodyByteCount"}"#))
        let text = " {\"a\":1e0,\"a\":1.00,\"escaped\":\"\\u0061\"} \n"
        let forms: [(String, [UInt8])] = [
            ("{\"kind\":\"bytes\",\"text\":\"é\"}", Array("é".utf8)),
            ("{\"kind\":\"bytes\",\"base64\":\"AP8=\"}", [0, 255]),
            ("{\"kind\":\"resource\",\"resource\":\"edited.json\"}", Array(text.utf8)),
        ]
        for (body, bytes) in forms {
            let authored = Data("""
            {"method":"POST","fields":[{"name":"Content-Length","value":{"derivedFrom":"bodyByteCount"}}],
             "body":\(body)}
            """.utf8)
            let decoded = try HTTPResourceCodingFixtures.decoder(resources: ["edited.json": bytes])
                .decode(HTTPRequestMessage.self, from: authored)
            #expect(decoded.head.headerFields[.contentLength] == String(bytes.count))
            switch decoded.body {
            case let .bytes(content): #expect(content == bytes)
            case let .resource(resource): #expect(resource.bytes() == bytes)
            case .absent: Issue.record("Expected content")
            }
        }
    }

    @Test
    func `derived fields preserve ordering and marker names remain valid literals`() throws {
        for literal in ["auto", "bodyByteCount", "derivedFrom"] {
            let original = try request(length: literal)
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(HTTPRequestMessage.self, from: data) == original)
            #expect(try !select(original).derivesContentLength)
        }
        let fields = HTTPFields([
            .init(name: .eTag, value: "first"),
            .init(name: .contentLength, value: "3"),
            .init(name: .eTag, value: "last"),
        ])
        let selected = try select(request(fields: fields))
        let data = try JSONEncoder().encode(selected)
        let decoded = try JSONDecoder().decode(HTTPRequestMessage.self, from: data)
        #expect(decoded == selected)
        #expect(Array(decoded.head.headerFields) == Array(fields))
    }

    @Test
    func `response derivation excludes partial and exceptional semantics`() throws {
        for status in [100, 101, 204, 205, 206, 304] {
            #expect(try !select(response(status: status)).head.value.derivesContentLength)
        }
        for method: HTTPRequest.Method in [.head, .connect] {
            #expect(try !select(response(), method: method).head.value.derivesContentLength)
        }
        for conclusion: HTTPBodyConclusion<String> in try [
            .openAtRecordingHorizon, .failed(.init(after: .zero, value: "failed")),
        ] {
            #expect(try !select(response(conclusion: conclusion)).head.value.derivesContentLength)
        }
        for status in [200, 404, 500] {
            let selected = try select(response(status: status))
            #expect(selected.head.value.derivesContentLength)
            let data = try JSONEncoder().encode(selected)
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            #expect(decoded == selected)
        }
    }

    @Test(arguments: [HTTPRequest.Method.get, .post, .head, .connect])
    func `construction validates derived response length before encoding`(_ method: HTTPRequest.Method) throws {
        let request = try request(method: method)
        let literal = try response()
        let derived = try select(literal)
        if method == .head || method == .connect {
            #expect(throws: HTTPMessageError.invalidField) {
                try HTTPInteraction(initialRequest: request, result: .received(derived))
            }
        } else {
            let interaction = try HTTPInteraction(initialRequest: request, result: .received(derived))
            #expect(interaction.result == .received(derived))
        }
        let interaction = try HTTPInteraction(initialRequest: request, result: .received(literal))
        #expect(interaction.result == .received(literal))
        _ = try HTTPInteraction<String>(initialRequest: request, result: .openAtRecordingHorizon)
        _ = try HTTPInteraction(initialRequest: request, result: .failed(HTTPTimed(after: .zero, value: "failed")))
    }

    @Test(arguments: [HTTPRequest.Method.head, .connect])
    func `decoding rejects derived response length for edited methods`(
        _ method: HTTPRequest.Method) throws
    {
        let interaction = try HTTPInteraction(
            initialRequest: request(method: .get), result: .received(select(response())))
        let data = try JSONEncoder().encode(interaction)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var request = try #require(object["initialRequest"] as? [String: Any])
        request["method"] = method.rawValue
        object["initialRequest"] = request
        let edited = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(HTTPInteraction<String>.self, from: edited)
        }
    }

    @Test
    func `edited response scales profile and length while validators remain literal`() throws {
        let selected = try select(response())
        let data = try JSONEncoder().encode(selected)
        let json = try #require(String(data: data, encoding: .utf8))
        let edited = Data(json.replacingOccurrences(of: "abc", with: "abcdefg").utf8)
        let decoded = try JSONDecoder().decode(Response.self, from: edited)
        #expect(decoded.head.value.head.headerFields[.contentLength] == "7")
        for name: HTTPField.Name in try [
            .eTag, #require(HTTPField.Name("Digest")), #require(HTTPField.Name("Content-MD5")),
        ] {
            #expect(decoded.head.value.head.headerFields[name] == "literal")
        }
        #expect(try decoded.body?.profile?.allocate(byteCount: 7).map(\.byteRange.count) == [2, 5])
        let literal = HTTPResponseHead(head: selected.head.value.head)
        let authored = try Response(head: .init(after: .zero, value: literal), body: #require(decoded.body))
        #expect(authored.head.value.head.headerFields[.contentLength] == "3")
        #expect(!authored.head.value.derivesContentLength)
    }

    @Test
    func `invalid markers fail at the decode boundary`() throws {
        let selected = try select(request())
        let data = try #require(String(data: JSONEncoder().encode(selected), encoding: .utf8))
        let marker = #"{"derivedFrom":"bodyByteCount"}"#
        #expect(data.contains(marker))
        let responseData = try #require(String(data: JSONEncoder().encode(select(response())), encoding: .utf8))
        #expect(responseData.contains(marker))
        for invalid in [
            #"{"derivedFrom":"unknown"}"#, #"{"derivedFrom":true}"#, #"{"derivedFrom":null}"#,
            #"{"derivedFrom":"bodyByteCount","extra":true}"#, #"{"bodyByteCount":true}"#, "{}",
        ] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(HTTPRequestMessage.self,
                                         from: Data(data.replacingOccurrences(of: marker, with: invalid).utf8))
            }
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(Response.self,
                                         from: Data(responseData.replacingOccurrences(of: marker, with: invalid).utf8))
            }
        }
        for edited in [
            data.replacingOccurrences(of: "Content-Length", with: "ETag"),
            data.replacingOccurrences(of: "POST", with: "HEAD"),
            data.replacingOccurrences(of: "\"abc\"", with: "null"),
        ] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(HTTPRequestMessage.self, from: Data(edited.utf8))
            }
        }
    }

    @Test
    func `conflicting derived lengths identify the field list`() throws {
        let json = """
        {"method":"POST","fields":[
            {"name":"Content-Length","value":{"derivedFrom":"bodyByteCount"}},
            {"name":"content-length","value":"3"}
        ],"body":{"kind":"bytes","text":"abc"}}
        """
        do {
            _ = try JSONDecoder().decode(HTTPRequestMessage.self, from: Data(json.utf8))
            Issue.record("Expected conflicting Content-Length fields")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.codingPath.map(\.stringValue) == ["fields"])
        }
    }

    @Test
    func `response body edits resolve every storage form and reject incomplete derived content`() throws {
        let selected = try select(response())
        let json = try #require(String(data: JSONEncoder().encode(selected), encoding: .utf8))
        let oldBody = "{\"kind\":\"bytes\",\"text\":\"abc\"}"
        // Use a sorted encoder so this independent body fragment has stable ordering.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let canonical = try #require(String(data: encoder.encode(selected), encoding: .utf8))
        #expect(canonical.contains(oldBody))
        let forms: [(String, [UInt8])] = [
            ("{\"kind\":\"bytes\",\"text\":\"é\"}", Array("é".utf8)),
            ("{\"base64\":\"AP8BAg==\",\"kind\":\"bytes\"}", [0, 255, 1, 2]),
            ("{\"kind\":\"resource\",\"resource\":\"reply.json\"}", Array(" {\"x\":1e0,\"x\":1.00} ".utf8)),
        ]
        for (body, bytes) in forms {
            let edited = Data(canonical.replacingOccurrences(of: oldBody, with: body).utf8)
            let decoded = try HTTPResourceCodingFixtures.decoder(resources: ["reply.json": bytes])
                .decode(Response.self, from: edited)
            #expect(decoded.head.value.head.headerFields[.contentLength] == String(bytes.count))
            let allocation = try decoded.body?.profile?.allocate(byteCount: bytes.count)
            #expect(allocation?.last?.byteRange.upperBound == bytes.count)
            if case let .resource(resource) = decoded.body?.content {
                #expect(resource.bytes() == bytes)
            }
        }
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(selected)) as? [String: Any])
        var next = try #require(object["next"] as? [String: Any])
        var body = try #require(next["body"] as? [String: Any])
        body["conclusion"] = ["kind": "open"]
        next["body"] = body
        object["next"] = next
        let partial = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Response.self, from: partial) }
        let headData = try encoder.encode(selected.head.value)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(HTTPResponseHead.self, from: headData) }
        for status in [204, 206, 304] {
            let edited = Data(json.replacingOccurrences(of: "200", with: String(status)).utf8)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(Response.self, from: edited) }
        }
    }

    @Test
    func `preparation precedes proof and storage placement preserves selected length`() throws {
        let raw = try request()
        let preparation = ValuePreparation<HTTPRequestMessage>(redact: { value in
            try HTTPRequestMessage(head: value.head, body: .bytes([]))
        })
        let reporter = try DiagnosticReporter(scenarioID: ScenarioID(rawValue: "http-length"),
                                              definition: ScenarioDefinition(attachments: []))
        let prepared = try preparation.prepare(capturing: { raw }, purpose: .recording, reporter: reporter)
        #expect(!HTTPContentLength.request(prepared).derivesContentLength)
        let selected = try select(raw)
        let policy = HTTPBodyStoragePolicy(fallback: .resource(fileExtension: "json"), useStandardRules: false)
        let stored = try policy.request(ValuePreparation().admitPrepared(selected), resourceStem: "request")
        #expect(stored.derivesContentLength)
        #expect(stored.head == selected.head)
    }

    private func request(method: HTTPRequest.Method = .post, body: HTTPRequestBody = .bytes(Array("abc".utf8)),
                         length: String = "3", fields: HTTPFields? = nil) throws -> HTTPRequestMessage
    {
        let fields = fields ?? HTTPFields([.init(name: .contentLength, value: length)])
        let head = HTTPRequest(method: method, scheme: nil, authority: nil, path: nil, headerFields: fields)
        return try HTTPRequestMessage(head: head, body: body)
    }

    private func select(_ request: HTTPRequestMessage) throws -> HTTPRequestMessage {
        try HTTPContentLength.request(ValuePreparation().admitPrepared(request))
    }

    private func select(_ response: Response, method: HTTPRequest.Method = .get) throws -> Response {
        try HTTPContentLength.response(ValuePreparation().admitPrepared(response), requestMethod: method)
    }

    private func response(status: Int = 200, conclusion: HTTPBodyConclusion<String>? = nil) throws -> Response {
        let fields = try HTTPFields([
            .init(name: .contentLength, value: "3"), .init(name: .eTag, value: "literal"),
            .init(name: #require(HTTPField.Name("Digest")), value: "literal"),
            .init(name: #require(HTTPField.Name("Content-MD5")), value: "literal"),
        ])
        let head = HTTPResponseHead(head: HTTPResponse(status: .init(code: status), headerFields: fields))
        let profile = try HTTPBodyProfile(segments: [
            .init(byteWeight: 1, after: .zero), .init(byteWeight: 2, after: .zero),
        ])
        return try Response(head: .init(after: .zero, value: head), body: .init(
            content: .bytes(Array("abc".utf8)), profile: profile,
            conclusion: conclusion ?? .returned(HTTPBodyCompletion(after: .zero))))
    }
}

private extension HTTPDelay {
    static var zero: Self {
        get throws { try Self(milliseconds: .observed(0)) }
    }
}
