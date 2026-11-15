import DioramaCore
import DioramaHTTP
import Foundation
import Testing

struct HTTPAuthenticationPreparationTests {
    @Test(arguments: [nil, "", "secret-marker-user"] as [String?])
    func `defaults preserve username shape and all other metadata`(_ user: String?) throws {
        let reporter = try reporter()
        let preparation = HTTPPreparation()
        let credential = HTTPAuthenticationCredential(user: user, hasPassword: false, persistence: .synchronizable)
        let challenge = try challenge(credential)
        let expected = HTTPAuthenticationCredential(
            user: user.map { $0.isEmpty ? "" : "redacted" }, hasPassword: false, persistence: .synchronizable)
        let selected = preparation.authenticationCredential()
        let proposed = preparation.authenticationChallenge()
        let value = try selected.prepare(capturing: { credential }, purpose: .recording, reporter: reporter).value
        let captured = try proposed.prepare(capturing: { challenge }, purpose: .recording, reporter: reporter).value
        #expect(value == expected)
        #expect(captured.proposedCredential == expected)
        #expect(captured.method == challenge.method)
        #expect(captured.host == challenge.host)
        #expect(captured.port == challenge.port)
        #expect(captured.protocol == challenge.protocol)
        #expect(captured.realm == challenge.realm)
        #expect(captured.isProxy == challenge.isProxy)
        #expect(captured.previousFailureCount == challenge.previousFailureCount)
        #expect(try selected.prepare(capturing: { value }, purpose: .replay, reporter: reporter).value == value)
        #expect(try proposed.prepare(capturing: { captured }, purpose: .replay, reporter: reporter).value == captured)
        let encoded = try JSONEncoder().encode(captured)
        #expect(try !#require(String(data: encoded, encoding: .utf8)).contains("secret-marker"))
        let decoded = try JSONDecoder().decode(HTTPAuthenticationChallenge.self, from: encoded)
        #expect(try proposed.admitPrepared(decoded).value == captured)
        #expect(try selected.admitPrepared(value).value == expected)
        #expect(credential.user == user)
        #expect(challenge.proposedCredential == credential)
        #expect(reporter.freeze().diagnostics.isEmpty)
    }

    @Test
    func `configured constants share a policy and remain independent between instances`() throws {
        let reporter = try reporter()
        let first = try HTTPPreparation(authenticationUsername: .constant("user-a"))
        let second = try HTTPPreparation(authenticationUsername: .constant("user-b"))
        let raw = HTTPAuthenticationCredential(user: "secret-marker", hasPassword: true, persistence: .forSession)
        let challenge = try challenge(raw)
        let firstAnswer = try first.authenticationCredential()
            .prepare(capturing: { raw }, purpose: .recording, reporter: reporter).value
        let secondAnswer = try second.authenticationCredential()
            .prepare(capturing: { raw }, purpose: .replay, reporter: reporter).value
        #expect(firstAnswer.user == "user-a")
        #expect(secondAnswer.user == "user-b")
        #expect(try first.authenticationChallenge()
            .prepare(capturing: { challenge }, purpose: .recording, reporter: reporter)
            .value.proposedCredential == firstAnswer)
        #expect(try second.authenticationChallenge()
            .prepare(capturing: { challenge }, purpose: .recording, reporter: reporter)
            .value.proposedCredential == secondAnswer)
        let retry = HTTPAuthenticationRetry<String>(result: .openAtRecordingHorizon)
        let phase = try HTTPAuthenticationPhase(
            after: HTTPDelay(milliseconds: .observed(0)), challenge: challenge,
            outcome: .useCredential(firstAnswer, retry))
        #expect(try phase.continuation(for: .useCredential(firstAnswer)) == .retry(retry))
        #expect(throws: HTTPAuthenticationSelectionError.incompatibleDecision) {
            try phase.continuation(for: .useCredential(secondAnswer))
        }
        #expect(throws: HTTPAuthenticationPreparationError.emptyUsernameReplacement) {
            try HTTPAuthenticationUsernameRule.constant("")
        }
    }

    @Test
    func `admission rejects raw and differently configured identities without transforming them`() throws {
        let reporter = try reporter()
        let preparation = try HTTPPreparation(authenticationUsername: .constant("user-a"))
        let credential = HTTPAuthenticationCredential(user: "user-a", hasPassword: true, persistence: .none)
        let policy = preparation.authenticationCredential(redact: { _ in throw TestError.transformMustNotRun },
                                                          normalize: { _ in throw TestError.transformMustNotRun })
        let proposed = preparation.authenticationChallenge(redact: { _ in throw TestError.transformMustNotRun },
                                                           normalize: { _ in throw TestError.transformMustNotRun })
        let decoded = try JSONDecoder().decode(
            HTTPAuthenticationCredential.self, from: JSONEncoder().encode(credential))
        #expect(try policy.admitPrepared(decoded).value == credential)
        let preparedChallenge = try challenge(credential)
        #expect(try proposed.admitPrepared(preparedChallenge).value == preparedChallenge)
        for user in ["secret-marker", "redacted", "user-b"] {
            let incompatible = HTTPAuthenticationCredential(user: user, hasPassword: true, persistence: .none)
            #expect(throws: PreparationFailure.self) { try policy.admitPrepared(incompatible) }
            let incompatibleChallenge = try challenge(incompatible)
            #expect(throws: PreparationFailure.self) { try proposed.admitPrepared(incompatibleChallenge) }
        }
        let absent = try challenge(nil)
        #expect(try proposed.admitPrepared(absent).value == absent)
        #expect(try preparation.authenticationChallenge()
            .prepare(capturing: { absent }, purpose: .recording, reporter: reporter).value == absent)
        #expect(reporter.freeze().diagnostics.isEmpty)
    }

    @Test(arguments: ["a", "b"])
    func `custom mapping sees original identities and preserves distinct safe users`(_ suffix: String) throws {
        let rule = HTTPAuthenticationUsernameRule(redact: { user in
            switch user {
            case "secret-marker-a", "user-a": "user-a"
            case "secret-marker-b", "user-b": "user-b"
            default: throw TestError.unexpectedIdentity
            }
        }, validate: { user in
            guard ["user-a", "user-b"].contains(user) else { throw TestError.unexpectedIdentity }
        })
        let preparation = HTTPPreparation(authenticationUsername: rule)
        let reporter = try reporter()
        let raw = HTTPAuthenticationCredential(
            user: "secret-marker-\(suffix)", hasPassword: true, persistence: .permanent)
        let challenge = try challenge(raw)
        let expected = HTTPAuthenticationCredential(user: "user-\(suffix)", hasPassword: true, persistence: .permanent)
        let selected = preparation.authenticationCredential(normalize: { value in
            #expect(value == expected)
            return value
        })
        let proposed = preparation.authenticationChallenge(normalize: { value in
            #expect(value.proposedCredential == expected)
            return value
        })
        for purpose in [PreparationPurpose.recording, .replay] {
            #expect(try selected.prepare(capturing: { raw }, purpose: purpose, reporter: reporter).value == expected)
            #expect(try proposed.prepare(capturing: { challenge }, purpose: purpose, reporter: reporter)
                .value.proposedCredential == expected)
        }
        #expect(try selected.prepare(capturing: { expected }, purpose: .replay, reporter: reporter).value == expected)
        #expect(try selected.admitPrepared(expected).value == expected)
        #expect(throws: PreparationFailure.self) { try selected.admitPrepared(raw) }
        #expect(reporter.freeze().diagnostics.isEmpty)
    }

    @Test
    func `final validation rejects reintroduced identities and reports safe recording failure`() throws {
        let reporter = try reporter()
        let raw = HTTPAuthenticationCredential(user: "secret-marker", hasPassword: true, persistence: .none)
        let challenge = try challenge(raw)
        let preparation = HTTPPreparation()
        let selected = preparation.authenticationCredential(normalize: { value in
            #expect(value.user == "redacted")
            return raw
        })
        let proposed = preparation.authenticationChallenge(redact: { value in
            #expect(value.proposedCredential?.user == "redacted")
            return challenge
        })
        #expect(throws: PreparationFailure.self) {
            try selected.prepare(capturing: { raw }, purpose: .recording, reporter: reporter)
        }
        #expect(throws: PreparationFailure.self) {
            try proposed.prepare(capturing: { challenge }, purpose: .recording, reporter: reporter)
        }
        let report = reporter.freeze()
        #expect(report.diagnostics.count == 2)
        #expect(report.diagnostics.allSatisfy { $0.diagnostic.issue == .preparationFailed(.validation) })
        #expect(!report.recordingHealth.isHealthy)
        #expect(!String(describing: report).contains("secret-marker"))
    }

    @Test
    func `empty custom replacements fail safely without poisoning replay health`() throws {
        let rule = HTTPAuthenticationUsernameRule(redact: { _ in "" }, validate: { _ in })
        let policy = HTTPPreparation(authenticationUsername: rule).authenticationCredential()
        let reporter = try reporter()
        let raw = HTTPAuthenticationCredential(user: "secret-marker", hasPassword: true, persistence: .none)
        #expect(throws: PreparationFailure.self) {
            try policy.prepare(capturing: { raw }, purpose: .replay, reporter: reporter)
        }
        let report = reporter.freeze()
        #expect(report.diagnostics.count == 1)
        #expect(report.diagnostics.first?.diagnostic.issue == .preparationFailed(.redaction))
        #expect(report.recordingHealth.isHealthy)
        #expect(!String(describing: report).contains("secret-marker"))
    }

    private func challenge(_ credential: HTTPAuthenticationCredential?) throws -> HTTPAuthenticationChallenge {
        try HTTPAuthenticationChallenge(
            method: .digest, host: "proxy.example.invalid", port: 8080, protocol: "http", realm: "example-realm",
            isProxy: true, previousFailureCount: 2, proposedCredential: credential)
    }

    private func reporter() throws -> DiagnosticReporter {
        try DiagnosticReporter(
            scenarioID: ScenarioID(rawValue: "authentication-preparation"),
            definition: ScenarioDefinition(attachments: []))
    }

    private enum TestError: Error { case transformMustNotRun, unexpectedIdentity }
}
