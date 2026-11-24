import DioramaCore
import DioramaHTTP
import DioramaURLSession
import Foundation
import HTTPTypes
import Testing

struct URLSessionAuthenticationTests {
    @Test(arguments: [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest])
    func `native defaults redact proposed and selected usernames without changing credentials`(
        _ method: String) throws
    {
        let reporter = try reporter()
        let credential = URLCredential(
            user: "secret-marker-user", password: "secret-marker-password", persistence: .none)
        let native = try challenge(method: method, credential: credential)
        let proposed = try URLSessionAuthentication.capture(native, reporter: reporter).value
        let selected = try URLSessionAuthentication.decision(.useCredential, credential: credential,
                                                             purpose: .recording, reporter: reporter)
        let expected = HTTPAuthenticationCredential(user: "redacted", hasPassword: true, persistence: .none)
        #expect(proposed.proposedCredential == expected)
        #expect(selected == .useCredential(expected))
        #expect(proposed.host == native.protectionSpace.host)
        #expect(proposed.realm == native.protectionSpace.realm)
        let other = URLCredential(user: "other-live-user", password: "other-password", persistence: .none)
        #expect(try URLSessionAuthentication.decision(.useCredential, credential: other,
                                                      purpose: .replay, reporter: reporter) == selected)
        let encoded = try JSONEncoder().encode(proposed.proposedCredential)
        #expect(try !#require(String(data: encoded, encoding: .utf8)).contains("secret-marker"))
        #expect(credential.user == "secret-marker-user")
        #expect(native.proposedCredential === credential)
        #expect(reporter.freeze().diagnostics.isEmpty)
    }

    @Test
    func `one configured username rule prepares both native entry points`() throws {
        let reporter = try reporter()
        let preparation = try HTTPPreparation(authenticationUsername: .constant("user-a"))
        let credential = URLCredential(
            user: "secret-marker-user", password: "secret-marker-password", persistence: .none)
        let native = try challenge(credential: credential)
        let proposed = try URLSessionAuthentication.capture(native, preparation: preparation.authenticationChallenge(),
                                                            reporter: reporter).value
        let selected = try URLSessionAuthentication.decision(
            .useCredential, credential: credential, preparation: preparation.authenticationCredential(),
            purpose: .recording, reporter: reporter)
        let expected = HTTPAuthenticationCredential(user: "user-a", hasPassword: true, persistence: .none)
        #expect(proposed.proposedCredential == expected)
        #expect(selected == .useCredential(expected))
        #expect(try preparation.authenticationChallenge().admitPrepared(proposed).value == proposed)
        #expect(throws: PreparationFailure.self) {
            try HTTPPreparation().authenticationChallenge().admitPrepared(proposed)
        }
        let rule = HTTPAuthenticationUsernameRule(redact: { _ in throw TestError.secret }, validate: { _ in })
        let failing = HTTPPreparation(authenticationUsername: rule).authenticationChallenge()
        #expect(throws: PreparationFailure.self) {
            try URLSessionAuthentication.capture(native, preparation: failing, reporter: reporter)
        }
        let report = reporter.freeze()
        #expect(report.diagnostics.count == 1)
        #expect(report.diagnostics.first?.diagnostic.issue == .preparationFailed(.redaction))
        #expect(!report.recordingHealth.isHealthy)
        #expect(!String(describing: report).contains("secret-marker"))
        #expect(credential.user == "secret-marker-user")
    }

    @Test(arguments: [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest])
    func `native challenge capture prepares proposed identity without reading or encoding passwords`(
        _ method: String) throws
    {
        let reporter = try reporter()
        let credential = URLCredential(
            user: "secret-marker-user",
            password: "secret-marker-password",
            persistence: .forSession)
        let native = try challenge(method: method, credential: credential, count: 2)
        let policy = ValuePreparation<HTTPAuthenticationChallenge>(redact: { value in
            try HTTPAuthenticationChallenge(
                method: value.method, host: value.host, port: value.port, protocol: value.protocol,
                realm: "fixture-realm",
                isProxy: value.isProxy, previousFailureCount: value.previousFailureCount,
                proposedCredential: value.proposedCredential.map {
                    HTTPAuthenticationCredential(
                        user: "fixture-user",
                        hasPassword: $0.hasPassword,
                        persistence: $0.persistence)
                })
        }, normalize: { value in
            #expect(value.realm == "fixture-realm")
            #expect(value.proposedCredential?.user == "fixture-user")
            return value
        }, validate: { value in
            guard value.realm == "fixture-realm",
                  value.proposedCredential?.user == "fixture-user" else { throw TestError.secret }
        })
        let value = try URLSessionAuthentication.capture(native, preparation: policy, reporter: reporter).value
        #expect(value.method == (method == NSURLAuthenticationMethodHTTPBasic ? .basic : .digest))
        #expect(value.host == "example.invalid")
        #expect(value.port == 443)
        #expect(value.protocol == "https")
        #expect(value.previousFailureCount == 2)
        #expect(value.proposedCredential?.hasPassword == true)
        #expect(value.proposedCredential?.persistence == .forSession)
        let data = try JSONEncoder().encode(value)
        #expect(try !#require(String(data: data, encoding: .utf8)).contains("secret-marker"))
        #expect(try policy.admitPrepared(JSONDecoder().decode(HTTPAuthenticationChallenge.self, from: data))
            .value == value)
        #expect(native.proposedCredential === credential)
        #expect(native.proposedCredential?.user == "secret-marker-user")
        #expect(native.protectionSpace.realm == "secret-marker-realm")
        #expect(reporter.freeze().diagnostics.isEmpty)
    }

    @Test
    func `native dispositions prepare current credential shape without comparing password contents`() throws {
        let reporter = try reporter()
        let policy = try credentialPolicy()
        let native = URLCredential(user: "secret-marker-user", password: "secret-marker-password", persistence: .none)
        let answer = try URLSessionAuthentication.decision(.useCredential, credential: native, preparation: policy,
                                                           purpose: .recording, reporter: reporter)
        let another = URLCredential(user: "other-live-user", password: "different-password", persistence: .none)
        let replay = try URLSessionAuthentication.decision(.useCredential, credential: another, preparation: policy,
                                                           purpose: .replay, reporter: reporter)
        #expect(answer == replay)
        let shape = HTTPAuthenticationCredential(user: "fixture-user", hasPassword: true, persistence: .none)
        #expect(answer == .useCredential(shape))
        let metadata = try HTTPAuthenticationChallenge(
            method: .basic,
            host: "example.invalid",
            port: 443,
            protocol: "https",
            realm: nil,
            isProxy: false,
            previousFailureCount: 0,
            proposedCredential: nil)
        let delay = try HTTPDelay(milliseconds: .observed(3))
        let failure = try URLSessionFailure(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)
        let retry = HTTPAuthenticationRetry(result: HTTPAttemptResult<URLSessionFailure>.failed(.init(
            after: delay,
            value: failure)))
        let phase = HTTPAuthenticationPhase(after: delay, challenge: metadata, outcome: .useCredential(shape, retry))
        #expect(try phase.continuation(for: replay) == .retry(retry))
        let root = try HTTPInteraction(initialRequest: HTTPRequestMessage(head: HTTPRequest(
            method: .get, scheme: "https", authority: "example.invalid", path: "/"), body: .absent),
        result: .received(HTTPResponseNode(
            head: .init(
                after: delay,
                value: HTTPResponseHead(head: HTTPResponse(status: .unauthorized))),
            next: .authenticate(phase))))
        let data = try JSONEncoder().encode(root)
        #expect(try JSONDecoder().decode(HTTPInteraction<URLSessionFailure>.self, from: data) == root)
        #expect(try !#require(String(data: data, encoding: .utf8)).contains("secret-marker"))
        let answers: [(URLSession.AuthChallengeDisposition, HTTPAuthenticationDecision)] = [
            (.performDefaultHandling, .performDefaultHandling), (.rejectProtectionSpace, .rejectProtectionSpace),
            (.cancelAuthenticationChallenge, .cancel),
        ]
        for (nativeAnswer, expected) in answers {
            let unused = ValuePreparation<HTTPAuthenticationCredential>(redact: { _ in throw TestError.secret })
            #expect(try URLSessionAuthentication.decision(nativeAnswer, credential: native, preparation: unused,
                                                          purpose: .replay, reporter: reporter) == expected)
        }
        #expect(reporter.freeze().diagnostics.isEmpty)
    }

    @Test
    func `invalid native methods responses and missing credentials fail through safe preparation`() throws {
        let reporter = try reporter()
        let invalid = try [
            challenge(method: NSURLAuthenticationMethodDefault), challenge(status: 200), challenge(status: nil),
            challenge(count: -1),
        ]
        for native in invalid {
            #expect(throws: PreparationFailure.self) {
                try URLSessionAuthentication.capture(native, preparation: ValuePreparation(), reporter: reporter)
            }
        }
        #expect(throws: PreparationFailure.self) {
            try URLSessionAuthentication.decision(.useCredential, credential: nil, preparation: credentialPolicy(),
                                                  purpose: .recording, reporter: reporter)
        }
        let report = reporter.freeze()
        #expect(report.diagnostics.count == invalid.count + 1)
        #expect(!report.recordingHealth.isHealthy)
        #expect(!String(describing: report).contains("secret-marker"))
        #expect(report.diagnostics.allSatisfy { $0.diagnostic.issue == .conversionFailed })
    }

    @Test
    func `failed identity preparation reports once preserves native values and blocks candidate`() throws {
        let reporter = try reporter()
        let native = URLCredential(user: "secret-marker", password: "secret-marker", persistence: .none)
        let policy = ValuePreparation<HTTPAuthenticationCredential>(redact: { _ in throw TestError.secret })
        #expect(throws: PreparationFailure.self) {
            try URLSessionAuthentication.decision(.useCredential, credential: native, preparation: policy,
                                                  purpose: .recording, reporter: reporter)
        }
        let report = reporter.freeze()
        #expect(report.diagnostics.count == 1)
        #expect(report.diagnostics.first?.diagnostic.issue == .preparationFailed(.redaction))
        #expect(!report.recordingHealth.isHealthy)
        #expect(!String(describing: report).contains("secret-marker"))
        #expect(native.user == "secret-marker")
        let replayReporter = try self.reporter()
        #expect(throws: PreparationFailure.self) {
            try URLSessionAuthentication.decision(.useCredential, credential: native, preparation: policy,
                                                  purpose: .replay, reporter: replayReporter)
        }
        #expect(replayReporter.freeze().recordingHealth.isHealthy)
    }

    @Test
    func `native proxy metadata belongs to a 407 without copying the failure response`() throws {
        let reporter = try reporter()
        let url = try #require(URL(string: "https://example.invalid/"))
        let space = URLProtectionSpace(proxyHost: "proxy.invalid", port: 8080,
                                       type: NSURLProtectionSpaceHTTPSProxy, realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let native = URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: HTTPURLResponse(url: url, statusCode: 407, httpVersion: nil, headerFields: nil),
            error: nil, sender: AuthenticationSender())
        let value = try URLSessionAuthentication.capture(native, preparation: ValuePreparation(), reporter: reporter)
            .value
        #expect(value.isProxy)
        #expect(value.host == "proxy.invalid")
        #expect(value.port == 8080)
        #expect(value.realm == nil)
        #expect(value.proposedCredential == nil)
        #expect(try JSONDecoder().decode(HTTPAuthenticationChallenge.self, from: JSONEncoder().encode(value)) == value)
        #expect(reporter.freeze().diagnostics.isEmpty)
    }

    private func credentialPolicy() throws -> ValuePreparation<HTTPAuthenticationCredential> {
        try HTTPPreparation(authenticationUsername: .constant("fixture-user")).authenticationCredential()
    }

    private func challenge(method: String = NSURLAuthenticationMethodHTTPBasic, status: Int? = 401,
                           credential: URLCredential? = nil, count: Int = 0) throws -> URLAuthenticationChallenge
    {
        let url = try #require(URL(string: "https://example.invalid/"))
        let response = status.flatMap { HTTPURLResponse(url: url, statusCode: $0, httpVersion: nil, headerFields: nil) }
        return URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(host: "example.invalid", port: 443, protocol: "https",
                                                realm: "secret-marker-realm", authenticationMethod: method),
            proposedCredential: credential, previousFailureCount: count, failureResponse: response, error: nil,
            sender: AuthenticationSender())
    }

    private func reporter() throws -> DiagnosticReporter {
        try DiagnosticReporter(
            scenarioID: ScenarioID(rawValue: "authentication"),
            definition: ScenarioDefinition(attachments: []))
    }

    private enum TestError: Error { case secret }
}

private final class AuthenticationSender: NSObject, URLAuthenticationChallengeSender {
    func use(_: URLCredential, for _: URLAuthenticationChallenge) {
        Issue.record("No native answer is sent")
    }

    func continueWithoutCredential(for _: URLAuthenticationChallenge) {
        Issue.record("No native answer is sent")
    }

    func cancel(_: URLAuthenticationChallenge) {
        Issue.record("No native answer is sent")
    }

    func performDefaultHandling(for _: URLAuthenticationChallenge) {
        Issue.record("No native answer is sent")
    }

    func rejectProtectionSpaceAndContinue(with _: URLAuthenticationChallenge) {
        Issue.record("No native answer is sent")
    }
}
