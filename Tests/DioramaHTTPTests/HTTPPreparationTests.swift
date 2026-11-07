import DioramaCore
import DioramaHTTP
import Foundation
import HTTPTypes
import Testing

struct HTTPPreparationTests {
    @Test(arguments: [
        ("Authorization", "Bearer secret-marker", "Bearer redacted"),
        ("Proxy-Authorization", "Basic dXNlcjpzZWNyZXQ=", "Basic cmVkYWN0ZWQ6cmVkYWN0ZWQ="),
        ("Cookie", "session=secret-marker; other=secret-marker", "session=redacted; other=redacted"),
        (
            "Set-Cookie",
            "session=secret-marker; Path=/; Secure; HttpOnly",
            "session=redacted; Path=/; Secure; HttpOnly"),
        ("Authentication-Info", "nextnonce=secret-marker", "nextnonce=\"redacted\""),
        ("Proxy-Authentication-Info", "rspauth=secret-marker", "nextnonce=\"redacted\""),
    ])
    func `defaults are safe idempotent and accepted after decoding`(
        _ name: String,
        _ raw: String,
        _ expected: String) throws
    {
        let reporter = try reporter()
        let policy = HTTPPreparation().request(reporter: reporter)
        let input = try request(name, raw)
        let prepared = try policy.prepare(capturing: { input }, purpose: .recording, reporter: reporter).value
        #expect(prepared.head.headerFields.first?.value == expected)
        #expect(input.head.headerFields.first?.value == raw)
        let again = try policy.prepare(capturing: { prepared }, purpose: .replay, reporter: reporter)
        #expect(again.value == prepared)
        let data = try JSONEncoder().encode(prepared)
        #expect(try !#require(String(data: data, encoding: .utf8)).contains("secret-marker"))
        let decoded = try JSONDecoder().decode(HTTPRequestMessage.self, from: data)
        #expect(try policy.admitPrepared(decoded).value == prepared)
        #expect(throws: PreparationFailure.self) { try policy.admitPrepared(input) }
    }

    @Test(arguments: [
        "Authorization",
        "Proxy-Authorization",
        "Cookie",
        "Set-Cookie",
        "Authentication-Info",
        "Proxy-Authentication-Info",
    ])
    func `malformed credentials produce safe healthy warnings`(_ name: String) throws {
        let reporter = try reporter()
        let policy = HTTPPreparation().request(reporter: reporter)
        let input = try request(name, "secret-marker")
        let prepared = try policy.prepare(capturing: { input }, purpose: .recording, reporter: reporter)
        #expect(!String(describing: prepared).contains("secret-marker"))
        let report = reporter.freeze()
        #expect(report.diagnostics.count == 1)
        #expect(report.recordingHealth.isHealthy)
        #expect(!String(describing: report).contains("secret-marker"))
    }

    @Test
    func `explicit replacements permit authored tokens and custom keys`() throws {
        let name = try #require(HTTPField.Name("X-API-Key"))
        let credentials = try HTTPFieldRedactionPolicy(rules: [
            .authorization: .constant("Bearer fictional.jwt.token"),
            name: .constant("fixture"),
        ])
        let reporter = try reporter()
        let policy = HTTPPreparation(fieldRedaction: credentials).request(reporter: reporter)
        let input = try request("Authorization", "Bearer secret-marker")
        let value = try policy.prepare(capturing: { input }, purpose: .replay, reporter: reporter).value
        #expect(value.head.headerFields.first?.value == "Bearer fictional.jwt.token")
        #expect(try policy.admitPrepared(value).value == value)
        let custom = try request("X-API-Key", "secret-marker")
        #expect(try policy.prepare(capturing: { custom }, purpose: .recording, reporter: reporter)
            .value.head.headerFields.first?.value == "fixture")
        #expect(throws: HTTPMessageError.invalidField) {
            try HTTPFieldRedactionPolicy(rules: [name: .constant("bad\nvalue")])
        }
    }

    @Test
    func `normalizers see substitutes and cannot reintroduce credentials`() throws {
        let reporter = try reporter()
        let input = try request("Authorization", "Bearer secret-marker")
        let policy = HTTPPreparation().request(reporter: reporter, normalize: { value in
            #expect(value.head.headerFields.first?.value == "Bearer redacted")
            return input
        })
        #expect(throws: PreparationFailure.self) {
            try policy.prepare(capturing: { input }, purpose: .recording, reporter: reporter)
        }
        let report = reporter.freeze()
        #expect(!report.recordingHealth.isHealthy)
        #expect(!String(describing: report).contains("secret-marker"))
    }

    @Test
    func `response preparation retains repeated cookies and opaque fields`() throws {
        let reporter = try reporter()
        var fields = HTTPFields()
        fields.append(HTTPField(name: .setCookie, value: "a=secret-marker"))
        fields.append(HTTPField(name: .setCookie, value: "b=secret-marker"))
        fields.append(HTTPField(name: .wwwAuthenticate, value: "Basic realm=example"))
        fields.append(HTTPField(name: .userAgent, value: [0xFF]))
        let input = HTTPResponseHead(head: HTTPResponse(status: .ok, headerFields: fields))
        let policy = HTTPPreparation().response(reporter: reporter)
        let output = try policy.prepare(capturing: { input }, purpose: .recording, reporter: reporter).value
        #expect(output.head.headerFields.map(\.value).prefix(3) == [
            "a=redacted",
            "b=redacted",
            "Basic realm=example",
        ])
        #expect(output.head.headerFields.last?.withUnsafeBytesOfValue { Array($0) } == [0xFF])
        #expect(try policy.admitPrepared(output).value == output)
    }

    @Test
    func `typed body and failure transforms only run on capture`() throws {
        let reporter = try reporter()
        let policy: ValuePreparation<HTTPResponseBody> = HTTPPreparation().value(normalize: { _ in .bytes([1]) })
        #expect(try policy.admitPrepared(.bytes([2])).value == .bytes([2]))
        #expect(try policy.prepare(capturing: { .bytes([2]) }, purpose: .recording, reporter: reporter)
            .value == .bytes([1]))
        let failure: ValuePreparation<String> = HTTPPreparation()
            .value(redact: { _ in throw HTTPMessageError.invalidBody })
        #expect(throws: PreparationFailure.self) {
            try failure.prepare(capturing: { "secret-marker" }, purpose: .replay, reporter: reporter)
        }
        let report = reporter.freeze()
        #expect(report.recordingHealth.isHealthy)
        #expect(!String(describing: report).contains("secret-marker"))
    }

    @Test(arguments: [
        ("Authorization", "Basic invalid", true),
        ("Authorization", "Bearer bad token", true),
        ("Authorization", "Unknown secret-marker", true),
        ("Authorization", #"Digest username="secret-marker", nonce="secret-marker""#, false),
        ("Authorization", "Digest invalid", true),
        ("Cookie", "a=bad,value", true),
        ("Cookie", "=secret-marker", true),
        ("Cookie", "a=secret-marker;", true),
        ("Cookie", #"a="secret-marker""#, false),
        ("Set-Cookie", "a=secret-marker; Secure=secret-marker", true),
        ("Set-Cookie", "a=secret-marker; Unknown=secret-marker", true),
        ("Set-Cookie", "a=secret-marker; SameSite=bad", true),
        ("Set-Cookie", "a=secret-marker; Path", true),
        ("Set-Cookie", "a=secret-marker; Max-Age=60; SameSite=Lax; Domain=.example.invalid", false),
        ("Set-Cookie", "a=secret-marker; Expires=Wed, 09 Jun 2027 10:18:14 GMT; Partitioned", false),
        ("Authentication-Info", #"nextnonce="secret-marker", qop=auth"#, false),
    ])
    func `credential grammar preserves supported syntax or warns safely`(
        _ name: String, _ value: String, _ warns: Bool) throws
    {
        let reporter = try reporter()
        let policy = HTTPPreparation().request(reporter: reporter)
        let input = try request(name, value)
        let output = try policy.prepare(capturing: { input }, purpose: .recording, reporter: reporter).value
        #expect(!String(describing: output).contains("secret-marker"))
        #expect(output.body == input.body)
        #expect(try policy.admitPrepared(output).value == output)
        #expect(try policy.prepare(capturing: { output }, purpose: .replay, reporter: reporter).value == output)
        let report = reporter.freeze()
        #expect(report.diagnostics.count == (warns ? 1 : 0))
        #expect(report.recordingHealth.isHealthy)
    }

    private func request(_ name: String, _ value: String) throws -> HTTPRequestMessage {
        var fields = HTTPFields()
        try fields.append(HTTPField(name: #require(HTTPField.Name(name)), value: value))
        return try HTTPRequestMessage(
            head: HTTPRequest(method: .get, scheme: "https", authority: "example.invalid",
                              path: "/", headerFields: fields),
            body: .bytes([0, 255]))
    }

    private func reporter() throws -> DiagnosticReporter {
        try DiagnosticReporter(
            scenarioID: ScenarioID(rawValue: "http-preparation"),
            definition: ScenarioDefinition(attachments: []))
    }
}
