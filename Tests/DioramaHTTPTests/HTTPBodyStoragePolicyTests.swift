import DioramaCore
import DioramaHTTP
import Foundation
import HTTPTypes
import Testing

struct HTTPBodyStoragePolicyTests {
    @Test(arguments: [199, 200, 201])
    func `threshold counts prepared bytes before encoding`(_ count: Int) throws {
        for type in ["text/plain", "application/json", "text/html", "application/unknown"] {
            // Two-byte scalars and JSON escapes make character and serialized lengths differ.
            let bytes = Array(repeating: UInt8(34), count: count % 2) +
                Array(String(repeating: "é", count: count / 2).utf8)
            let body = try store(bytes, types: [type])
            #expect(try content(body) == bytes)
            if count <= 200 {
                #expect(body == .bytes(bytes))
                let object = try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode(body))
                #expect(object["text"] != nil)
            } else {
                #expect(path(body) != nil)
            }
        }
    }

    @Test
    func `defaults preserve image text and opaque bodies in canonical fixtures`() throws {
        let inputs: [(String?, [UInt8])] = [
            (nil, []),
            ("application/json", Array(#"{ "x":1.00, "x":2, "s":"\u0061" }"#.utf8)),
            ("image/png", [137, 80, 78, 71, 13, 10, 26, 10, 0, 255]),
            ("image/jpeg", [255, 216, 255, 0, 128]),
            ("text/plain", [0xE2, 0x82]),
            ("text/html", Array(repeating: 32, count: 201)),
            ("application/json", Array(repeating: 32, count: 201)),
            (nil, Array(repeating: 65, count: 201)),
            (nil, Array(repeating: 255, count: 201)),
        ]
        let bodies = try inputs.enumerated().map { index, input in
            try store(input.1, types: input.0.map { [$0] } ?? [], stem: "bodies/body-\(index)")
        }
        let url = try #require(Bundle.module.url(
            forResource: "body-storage", withExtension: "json", subdirectory: "Fixtures"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        #expect(try encoder.encode(bodies) + Data([10]) == Data(contentsOf: url))
        for (input, body) in zip(inputs, bodies) {
            #expect(try content(body) == input.1)
        }
    }

    @Test(arguments: [
        ("image/gif", Array("GIF89a".utf8), "gif"),
        ("image/gif", Array("GIF87a".utf8), "gif"),
        ("image/webp", Array("RIFF1234WEBP".utf8), "webp"),
        ("application/problem+json", Array(repeating: UInt8(32), count: 201), "json"),
        ("application/xml", Array(repeating: UInt8(32), count: 201), "xml"),
        ("text/xml", Array(repeating: UInt8(32), count: 201), "xml"),
        ("text/css", Array(repeating: UInt8(32), count: 201), "css"),
        ("text/csv", Array(repeating: UInt8(32), count: 201), "csv"),
        ("text/javascript", Array(repeating: UInt8(32), count: 201), "js"),
        ("application/javascript", Array(repeating: UInt8(32), count: 201), "js"),
        ("text/x-custom", Array(repeating: UInt8(32), count: 201), "txt"),
    ])
    func `supported type hints select deterministic suffixes`(
        _ type: String, _ bytes: [UInt8], _ suffix: String) throws
    {
        let body = try store(bytes, types: [type])
        #expect(path(body) == "bodies/reply." + suffix)
        #expect(try content(body) == bytes)
    }

    @Test
    func `all inline and explicit standard opt out preserve every new request and response body`() throws {
        let configured = HTTPBodyStoragePolicy(fallback: .inline, useStandardRules: false)
        let png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10] + Array(repeating: 0, count: 1016)
        let contents: [[UInt8]] = [[], [255], Array(repeating: 32, count: 201), png]
        let mediaTypes = [
            "image/png", "image/jpeg", "image/gif", "image/webp", "application/json",
            "application/problem+json", "text/html", "text/custom", "application/unknown",
        ]
        for policy in [HTTPBodyStoragePolicy.allInline, configured] {
            for type in mediaTypes {
                for bytes in contents {
                    #expect(try store(bytes, types: [type], policy: policy, stem: "../unused") == .bytes(bytes))
                    let request = try HTTPRequestMessage(
                        head: HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/",
                                          headerFields: [.contentType: type]),
                        body: .bytes(bytes))
                    #expect(try policy.request(ValuePreparation().admitPrepared(request), resourceStem: "../unused")
                        == request)
                }
            }
        }
    }

    @Test
    func `consumer overrides precede fallback when standard placement rules are disabled`() throws {
        let policy = HTTPBodyStoragePolicy(rules: [
            "image/png": .resource(),
            "application/json": .automatic(inlineByteLimit: 1),
        ], fallback: .inline, useStandardRules: false)
        let png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        #expect(try path(store(png, types: ["image/png"], policy: policy)) == "bodies/reply.png")
        #expect(try store([32], types: ["application/json"], policy: policy) == .bytes([32]))
        #expect(try path(store([32, 32], types: ["application/json"], policy: policy)) == "bodies/reply.json")
        #expect(try store(png, types: ["image/jpeg"], policy: policy) == .bytes(png))
        let text = Array(repeating: UInt8(32), count: 201)
        #expect(try store(text, types: ["text/html"], policy: policy) == .bytes(text))
        #expect(try store([255], policy: policy) == .bytes([255]))
    }

    @Test(arguments: [
        ("image/png", [UInt8(137), 80, 78, 71, 13, 10, 26, 10], "png"),
        ("text/html", [32], "html"), ("text/custom", [32], "txt"),
        ("application/problem+json", [32], "json"), ("application/json", [255], "json"),
        ("application/unknown", [32], "bin"), ("application/unknown", [255], "bin"),
    ])
    func `standard placement opt out retains rule based extensions`(
        _ type: String, _ bytes: [UInt8], _ suffix: String) throws
    {
        let policy = HTTPBodyStoragePolicy(fallback: .resource(), useStandardRules: false)
        let body = try store(bytes, types: [type], policy: policy)
        #expect(path(body) == "bodies/reply." + suffix)
        #expect(try content(body) == bytes)
        #expect(try path(store(bytes, types: [type], encodings: ["gzip"], policy: policy)) == "bodies/reply." + suffix)
    }

    @Test
    func `exact overrides precede builtins and fallback without depending on key order`() throws {
        let policy = HTTPBodyStoragePolicy(rules: [
            "image/png": .inline,
            "application/json": .automatic(inlineByteLimit: 0, fileExtension: "JSONDATA"),
            "text/html": .resource(fileExtension: "page"),
            "application/custom": .resource(),
        ], fallback: .inline)
        #expect(try store([1], types: ["image/png"], policy: policy) == .bytes([1]))
        #expect(try store([], types: ["application/json"], policy: policy) == .bytes([]))
        #expect(try path(store([1], types: ["\tAPPLICATION/JSON \t; charset=\"unterminated"], policy: policy)) ==
            "bodies/reply.JSONDATA")
        #expect(try path(store([], types: ["text/html"], policy: policy)) == "bodies/reply.page")
        #expect(try path(store([255], types: ["application/custom"], policy: policy)) == "bodies/reply.bin")
        let largeOpaque = Array(repeating: UInt8(255), count: 500)
        #expect(try store(largeOpaque, policy: policy) == .bytes(largeOpaque))
        // Fallback never replaces a recognized builtin's rule.
        #expect(try path(store(Array(repeating: 32, count: 201), types: ["text/plain"], policy: policy)) ==
            "bodies/reply.txt")
        let fallback = HTTPBodyStoragePolicy(fallback: .resource(fileExtension: "opaque"))
        #expect(try path(store([], policy: fallback)) == "bodies/reply.opaque")
        let unlimited = HTTPBodyStoragePolicy(fallback: .automatic(inlineByteLimit: .max))
        #expect(try store([255], policy: unlimited) == .bytes([255]))
    }

    @Test(arguments: [
        [], [""], ["; charset="], ["text /html"], ["application/json, text/plain"],
        ["text/html", "application/json"], ["image/png", "image/png"], ["*/html"], ["image/pn g"],
    ])
    func `missing repeated and unmatched hints use fallback`(_ types: [String]) throws {
        let policy = HTTPBodyStoragePolicy(fallback: .resource(fileExtension: "fallback"))
        #expect(try path(store([255], types: types, policy: policy)) == "bodies/reply.fallback")
    }

    @Test(arguments: [
        (" TEXT/HTML ; charset=UTF-8 ", "html"), ("text/html; note=\"a;b,c\"", "html"),
        ("text/html; note=\"a\\\"b\"", "html"), ("text/html;", "html"),
        ("text/html; ; charset=utf-8", "html"), ("text/html; note=\"\t\"", "html"),
        ("text/html; charset=", "html"), ("text/html; charset=\"unterminated", "html"),
        ("text/html; charset =utf-8", "html"), ("text/not a type; broken", "txt"),
        ("text/", "txt"), ("text/*", "txt"), ("text/html, application/json", "txt"),
        ("application/not a type+json; broken", "json"),
    ])
    func `header hints are truncated trimmed and lowercased without syntax validation`(
        _ type: String, _ suffix: String) throws
    {
        #expect(try path(store(Array(repeating: 32, count: 201), types: [type])) == "bodies/reply." + suffix)
    }

    @Test(arguments: [("image/png", "png"), ("image/jpeg", "jpeg"), ("image/gif", "gif"), ("image/webp", "webp")])
    func `image rule extensions do not depend on signatures or completeness`(_ type: String, _ suffix: String) throws {
        for bytes: [UInt8] in [[], [137, 80], [255], Array("not an image".utf8)] {
            let body = try store(bytes, types: [type])
            #expect(path(body) == "bodies/reply." + suffix)
            #expect(try content(body) == bytes)
        }
    }

    @Test
    func `resource extensions ignore body encoding and Content Encoding`() throws {
        let opaque = Array(repeating: UInt8(255), count: 201)
        #expect(try path(store(opaque, types: ["application/json"])) == "bodies/reply.json")
        for encoding in ["gzip", "br", "gzip, br", "", "unknown", "identity, gzip", "identity\u{00A0}"] {
            let bytes = Array(repeating: UInt8(32), count: 201)
            let body = try store(bytes, types: ["text/html"], encodings: [encoding])
            #expect(path(body) == "bodies/reply.html")
            #expect(try content(body) == bytes)
        }
        #expect(try path(store(Array(repeating: 32, count: 201), types: ["text/html"], encodings: [" Identity "])) ==
            "bodies/reply.html")
        let gzip: [UInt8] = [31, 139, 8, 0, 255]
        #expect(try store(gzip, types: ["application/json"], encodings: ["gzip"]) == .bytes(gzip))
        let policy = HTTPBodyStoragePolicy(rules: ["application/json": .resource(fileExtension: "gz")])
        #expect(try path(store(gzip, types: ["application/json"], encodings: ["gzip"], policy: policy)) ==
            "bodies/reply.gz")
    }

    @Test
    func `header normalization preserves original field bytes and trims only space and tab`() throws {
        let bytes = Array(repeating: UInt8(32), count: 201)
        let body = try ValuePreparation<HTTPResponseBody>().admitPrepared(.bytes(bytes))
        for value in [
            Array("text/html; note=\"".utf8) + [255] + [34],
            Array("text/html; note=\"a\\".utf8) + [128] + [34],
        ] {
            var fields = HTTPFields()
            fields.append(HTTPField(name: .contentType, value: value))
            let head = try ValuePreparation().admitPrepared(HTTPResponseHead(
                head: HTTPResponse(status: .ok, headerFields: fields)))
            let stored = try HTTPBodyStoragePolicy.default.response(body, head: head, resourceStem: "body")
            #expect(path(stored) == "body.html")
            #expect(head.value.head.headerFields.first?.withUnsafeBytesOfValue { Array($0) } == value)
        }
        let malformed = "text/html\u{00A0}"
        let policy = HTTPBodyStoragePolicy(fallback: .resource(fileExtension: "fallback"))
        #expect(try path(store(bytes, types: [malformed], policy: policy)) == "bodies/reply.txt")
    }

    @Test
    func `absence unavailable and baseline references bypass policy and stem validation`() throws {
        let policy = HTTPBodyStoragePolicy(fallback: .resource())
        let head = try preparedHead()
        let reference = try HTTPResponseBody.resource(
            HTTPResourceCodingFixtures.resource(path: "authored/literal.custom"))
        for body: HTTPResponseBody in [.absent, .unavailable, reference] {
            #expect(try policy.response(
                ValuePreparation().admitPrepared(body), head: head, resourceStem: "../bad") == body)
        }
        let message = try HTTPRequestMessage(head: HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/"))
        #expect(try policy.request(ValuePreparation().admitPrepared(message), resourceStem: "../bad") == message)
        let resource = try HTTPRequestMessage(
            head: message.head, body: .resource(HTTPResourceCodingFixtures.resource(path: "literal.bin")))
        #expect(try HTTPBodyStoragePolicy.default.request(
            ValuePreparation().admitPrepared(resource), resourceStem: "") == resource)
        // Even always-inline does not rewrite an owned baseline resource.
        let inline = HTTPBodyStoragePolicy.allInline
        #expect(try inline.response(
            ValuePreparation().admitPrepared(reference), head: head, resourceStem: "") == reference)
        #expect(try inline.request(ValuePreparation().admitPrepared(resource), resourceStem: "") == resource)
    }

    @Test
    func `prepared request selection keeps head and logical matching exact`() throws {
        let reporter = try DiagnosticReporter(
            scenarioID: ScenarioID(rawValue: "placement"), definition: ScenarioDefinition())
        let raw = try HTTPRequestMessage(head: HTTPRequest(
            method: .post, scheme: "https", authority: "example.invalid", path: "/",
            headerFields: [.contentType: "application/json"]),
        body: .bytes(Array("secret".utf8)))
        let preparation = HTTPPreparation().request(reporter: reporter, redact: { value in
            try HTTPRequestMessage(head: value.head, body: .bytes(Array(repeating: 32, count: 201)))
        })
        let prepared = try preparation.prepare(capturing: { raw }, purpose: .recording, reporter: reporter)
        let stored = try HTTPBodyStoragePolicy.default.request(prepared, resourceStem: "requests/0001")
        guard case let .resource(resource) = stored.body else { Issue.record("Expected resource"); return }
        #expect(resource.path == "requests/0001.json")
        #expect(resource.bytes() == Array(repeating: 32, count: 201))
        #expect(stored.head == raw.head)
        #expect(raw.body == .bytes(Array("secret".utf8)))
        #expect(try HTTPRequestMatcher().project(prepared) ==
            HTTPRequestMatcher().project(preparation.admitPrepared(stored)))
    }

    @Test(arguments: [
        ("/", ""), ("\\", ""), ("../png", "..png"), ("a/b", "ab"), ("a\\b", "ab"),
        ("/absolute", "absolute"), ("trailing/", "trailing"),
        ("/\u{FE0F}", "\u{FE0F}"), ("\\\u{FE0F}", "\u{FE0F}"), ("/\u{0301}", "\u{0301}"),
    ])
    func `extension overrides strip separator scalars and preserve remaining spelling`(
        _ suffix: String, _ sanitized: String) throws
    {
        let rules: [HTTPBodyStoragePolicy.Rule] = [
            .resource(fileExtension: suffix), .automatic(inlineByteLimit: 1, fileExtension: suffix),
        ]
        for rule in rules {
            let policy = HTTPBodyStoragePolicy(fallback: rule)
            let body = try store([0, 255], policy: policy)
            #expect(path(body) == "bodies/reply." + sanitized)
            #expect(try content(body) == [0, 255])
        }
    }

    @Test
    func `resource path validation still rejects a NUL in a literal suffix`() throws {
        let policy = HTTPBodyStoragePolicy(fallback: .resource(fileExtension: "bad\u{0}"))
        #expect(throws: HTTPMessageError.invalidResource) { try store([1], policy: policy) }
    }

    @Test
    func `rule keys are literal and do not receive validation normalization or wildcard behavior`() throws {
        let policy = HTTPBodyStoragePolicy(rules: [
            "image/png": .resource(fileExtension: "lower"), "IMAGE/PNG": .inline,
            "not a media type": .resource(fileExtension: "custom"),
            "text/*": .resource(fileExtension: "literal"), "": .resource(fileExtension: "empty"),
            "text/html; charset=utf-8": .resource(fileExtension: "unused"),
            " text/html": .resource(fileExtension: "unused"),
        ], fallback: .inline, useStandardRules: false)
        #expect(try path(store([1], types: ["IMAGE/PNG"], policy: policy)) == "bodies/reply.lower")
        #expect(try path(store([1], types: ["not a media type"], policy: policy)) == "bodies/reply.custom")
        #expect(try path(store([1], types: ["text/*"], policy: policy)) == "bodies/reply.literal")
        #expect(try path(store([1], types: [""], policy: policy)) == "bodies/reply.empty")
        for types in [[], ["text/plain"], ["text/html; charset=utf-8"], [" text/html"]] {
            #expect(try store([1], types: types, policy: policy) == .bytes([1]))
        }
    }

    @Test
    func `zero and maximum UInt limits retain inclusive thresholds without overflow`() throws {
        let contents: [[UInt8]] = [[], [1], [0, 255], Array(repeating: 32, count: 201)]
        let zero = HTTPBodyStoragePolicy(fallback: .automatic(inlineByteLimit: 0), useStandardRules: false)
        #expect(try store([], policy: zero, stem: "../unused") == .bytes([]))
        for bytes in contents.dropFirst() {
            let body = try store(bytes, policy: zero)
            #expect(path(body) == "bodies/reply.bin")
            #expect(try content(body) == bytes)
        }
        let resource = HTTPBodyStoragePolicy(fallback: .resource(), useStandardRules: false)
        for bytes in contents {
            let body = try store(bytes, policy: resource)
            #expect(path(body) == "bodies/reply.bin")
            #expect(try content(body) == bytes)
        }
        let maximum = HTTPBodyStoragePolicy(fallback: .automatic(inlineByteLimit: .max), useStandardRules: false)
        for bytes in contents {
            #expect(try store(bytes, policy: maximum, stem: "../unused") == .bytes(bytes))
        }
    }

    @Test(arguments: ["", ".", "..", "../escape", "/absolute", "a//b", "a/", "a\u{0}"])
    func `resource stem must have contained relative components`(_ stem: String) throws {
        let policy = HTTPBodyStoragePolicy(fallback: .resource())
        #expect(throws: HTTPMessageError.invalidResource) { try store([], policy: policy, stem: stem) }
        #expect(try store([], stem: stem) == .bytes([]))
    }

    @Test(arguments: ["a.", "a/CON", "a%2fb", "images/my photo", "images/画像"])
    func `literal resource stems retain their names when a suffix is appended`(_ stem: String) throws {
        let policy = HTTPBodyStoragePolicy(fallback: .resource(fileExtension: "bin"))
        let body = try store([], policy: policy, stem: stem)
        #expect(path(body) == stem + ".bin")
        #expect(try content(body).isEmpty)
    }

    private func store(_ bytes: [UInt8], types: [String] = [], encodings: [String] = [],
                       policy: HTTPBodyStoragePolicy = .default, stem: String = "bodies/reply") throws
        -> HTTPResponseBody
    {
        try policy.response(ValuePreparation().admitPrepared(.bytes(bytes)),
                            head: preparedHead(types: types, encodings: encodings), resourceStem: stem)
    }

    private func preparedHead(types: [String] = [], encodings: [String] = []) throws
        -> PreparedValue<HTTPResponseHead>
    {
        var fields = HTTPFields()
        for type in types {
            fields.append(HTTPField(name: .contentType, value: type))
        }
        for encoding in encodings {
            fields.append(HTTPField(name: .contentEncoding, value: encoding))
        }
        return try ValuePreparation().admitPrepared(HTTPResponseHead(
            head: HTTPResponse(status: .ok, headerFields: fields)))
    }

    private func path(_ body: HTTPResponseBody) -> String? {
        guard case let .resource(resource) = body else { return nil }
        return resource.path
    }

    private func content(_ body: HTTPResponseBody) throws -> [UInt8] {
        switch body {
        case let .bytes(bytes): bytes
        case let .resource(resource): resource.bytes()
        default: throw HTTPMessageError.invalidBody
        }
    }
}
