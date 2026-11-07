import DioramaCore
import DioramaHTTP
import HTTPTypes
import Testing

struct HTTPFieldRedactionTests {
    @Test
    func `custom decisions preserve bytes replace warn and remove in order`() throws {
        let reporter = try reporter()
        let name = try #require(HTTPField.Name("X-Custom"))
        let binary = try HTTPFieldValue(bytes: [0x80, 0xFF])
        let rule = HTTPFieldRedactionRule(redact: { value in
            switch value.text {
            case "secret": .replace(binary)
            case "unsupported": .replaceWithWarning(binary)
            case "omit": .remove
            default: .safe
            }
        }, validate: { value in
            guard value == binary else { throw HTTPMessageError.invalidField }
        })
        let preparation = HTTPPreparation(fieldRedaction: HTTPFieldRedactionPolicy(rules: [name: rule]))
        let policy = preparation.response(reporter: reporter)
        var fields = HTTPFields()
        for bytes in [binary.bytes, Array("secret".utf8), Array("omit".utf8), Array("unsupported".utf8)] {
            var field = HTTPField(name: name, value: bytes)
            field.indexingStrategy = .disallow
            fields.append(field)
            fields.append(HTTPField(name: .userAgent, value: "unchanged"))
        }
        let original = HTTPResponseHead(head: HTTPResponse(status: .ok, headerFields: fields))
        let value = try policy.prepare(capturing: { original }, purpose: .recording, reporter: reporter).value
        #expect(value.head.headerFields.map(\.name) == [
            name, .userAgent, name, .userAgent, .userAgent, name, .userAgent,
        ])
        let retained = value.head.headerFields.filter { $0.name == name }
        #expect(retained.allSatisfy { $0.withUnsafeBytesOfValue { Array($0) } == binary.bytes })
        #expect(retained.allSatisfy { $0.indexingStrategy == .disallow })
        #expect(original.head.headerFields.count == 8)
        #expect(binary.text == nil)
        #expect(try policy.admitPrepared(value).value == value)
        #expect(try policy.prepare(capturing: { value }, purpose: .replay, reporter: reporter).value == value)
        let report = reporter.freeze()
        #expect(report.diagnostics.map(\.diagnostic.issue) == [
            .system(DiagnosticLabel("http.redaction.replacement-warning")),
        ])
        #expect(report.recordingHealth.isHealthy)
        #expect(!String(describing: report).contains("unsupported"))
    }

    @Test
    func `removal overrides defaults case insensitively and rejects retained baselines`() throws {
        let reporter = try reporter()
        let lowerName = try #require(HTTPField.Name("authorization"))
        let policy = HTTPPreparation(fieldRedaction: HTTPFieldRedactionPolicy(rules: [lowerName: .remove]))
            .request(reporter: reporter)
        var fields = HTTPFields()
        fields.append(HTTPField(name: .authorization, value: "Bearer secret"))
        fields.append(HTTPField(name: .userAgent, value: "agent"))
        fields.append(HTTPField(name: lowerName, value: "Basic secret"))
        let input = try HTTPRequestMessage(head: HTTPRequest(method: .get, scheme: "https",
                                                             authority: "example.invalid", path: "/",
                                                             headerFields: fields))
        let output = try policy.prepare(capturing: { input }, purpose: .recording, reporter: reporter).value
        #expect(output.head.headerFields.map(\.name) == [.userAgent])
        #expect(try policy.admitPrepared(output).value == output)
        #expect(throws: PreparationFailure.self) { try policy.admitPrepared(input) }
        // Admission rejection is returned to its caller without reporting synthetic execution facts.
        #expect(reporter.freeze().diagnostics.isEmpty)
    }

    @Test
    func `prepared admission invokes validation without capture or warning`() throws {
        let reporter = try reporter()
        let rule = HTTPFieldRedactionRule(redact: { _ in
            Issue.record("Capture must not run during admission")
            throw HTTPMessageError.invalidField
        }, validate: { value in
            guard value.text == "authored" else { throw HTTPMessageError.invalidField }
        })
        let policy = HTTPPreparation(fieldRedaction: HTTPFieldRedactionPolicy(rules: [.authorization: rule]))
            .response(reporter: reporter)
        let valid = response("authored")
        #expect(try policy.admitPrepared(valid).value == valid)
        #expect(throws: PreparationFailure.self) { try policy.admitPrepared(response("secret")) }
        #expect(reporter.freeze().diagnostics.isEmpty)
    }

    @Test(arguments: [false, true])
    func `safe and warned replacements still undergo final validation`(_ warn: Bool) throws {
        let reporter = try reporter()
        let rule = HTTPFieldRedactionRule(redact: { value in
            warn ? .replaceWithWarning(value) : .safe
        }, validate: { _ in throw HTTPMessageError.invalidField })
        let policy = HTTPPreparation(fieldRedaction: HTTPFieldRedactionPolicy(rules: [.authorization: rule]))
            .response(reporter: reporter)
        #expect(throws: PreparationFailure.self) {
            try policy.prepare(capturing: { response("secret-marker") }, purpose: .recording, reporter: reporter)
        }
        let report = reporter.freeze()
        #expect(!report.recordingHealth.isHealthy)
        #expect(report.diagnostics.count == (warn ? 2 : 1))
        #expect(!String(describing: report).contains("secret-marker"))
    }

    @Test
    func `rule failures are safe and malformed replacement bytes are rejected`() throws {
        #expect(throws: HTTPMessageError.invalidField) { try HTTPFieldValue(bytes: [13, 10]) }
        let reporter = try reporter()
        let rule = HTTPFieldRedactionRule(redact: { _ in throw HTTPMessageError.invalidField }, validate: { _ in })
        let policy = HTTPPreparation(fieldRedaction: HTTPFieldRedactionPolicy(rules: [.authorization: rule]))
            .response(reporter: reporter)
        #expect(throws: PreparationFailure.self) {
            try policy.prepare(capturing: { response("secret-marker") }, purpose: .replay, reporter: reporter)
        }
        let report = reporter.freeze()
        #expect(report.recordingHealth.isHealthy)
        #expect(report.diagnostics.map(\.diagnostic.issue) == [.preparationFailed(.redaction)])
    }

    @Test
    func `built in rules can be assigned to custom fields`() throws {
        let reporter = try reporter()
        let rule = HTTPFieldRedactionPolicy(rules: [.userAgent: .cookies])
        let policy = HTTPPreparation(fieldRedaction: rule).response(reporter: reporter)
        var fields = HTTPFields()
        fields.append(HTTPField(name: .userAgent, value: "a=secret"))
        let input = HTTPResponseHead(head: HTTPResponse(status: .ok, headerFields: fields))
        let output = try policy.prepare(capturing: { input }, purpose: .recording, reporter: reporter).value
        #expect(output.head.headerFields.first?.value == "a=redacted")
        #expect(try policy.admitPrepared(output).value == output)
    }

    @Test
    func `normalization cannot reintroduce a removed field`() throws {
        let reporter = try reporter()
        let input = response("secret-marker")
        let policy = HTTPPreparation(fieldRedaction: HTTPFieldRedactionPolicy(rules: [.authorization: .remove]))
            .response(reporter: reporter, normalize: { value in
                #expect(value.head.headerFields.isEmpty)
                return input
            })
        #expect(throws: PreparationFailure.self) {
            try policy.prepare(capturing: { input }, purpose: .recording, reporter: reporter)
        }
        let report = reporter.freeze()
        #expect(!report.recordingHealth.isHealthy)
        #expect(report.diagnostics.map(\.diagnostic.issue) == [.preparationFailed(.validation)])
    }

    private func response(_ value: String) -> HTTPResponseHead {
        var fields = HTTPFields()
        fields.append(HTTPField(name: .authorization, value: value))
        return HTTPResponseHead(head: HTTPResponse(status: .ok, headerFields: fields))
    }

    private func reporter() throws -> DiagnosticReporter {
        try DiagnosticReporter(scenarioID: ScenarioID(rawValue: "field-rules"),
                               definition: ScenarioDefinition(attachments: []))
    }
}
