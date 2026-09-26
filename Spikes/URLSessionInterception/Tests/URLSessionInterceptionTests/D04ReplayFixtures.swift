import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct D04ReplayScenario: Sendable {
    var scheme = "Basic"
    var proxy = false
    var repeatCount = 0
    var proposed = false
    var failure = false
    var expectedDecision: String?
    var delay: Duration = .zero
}

final class D04ReplayFlow: Sendable {
    let delivery: D02ControlledDelivery
    let url: URL
    let scenario: D04ReplayScenario

    init(delivery: D02ControlledDelivery, url: URL, scenario: D04ReplayScenario) {
        self.delivery = delivery
        self.url = url
        self.scenario = scenario
    }

    func present(failures: Int) {
        let sender = D04Sender { decision in
            D04SyntheticProbe.decisions.withLock { $0.append(decision) }
            D04SyntheticProbe.decisionTimes.withLock { $0.append(.now) }
            if decision.name == "use", failures < self.scenario.repeatCount {
                self.present(failures: failures + 1)
            } else if self.scenario.delay == .zero {
                self.finish(decision)
            } else {
                Task {
                    do { try await Task.sleep(for: self.scenario.delay) } catch { return }
                    self.finish(decision)
                }
            }
        }
        D04SyntheticProbe.sender.withLock { $0 = sender }
        let method = scenario.scheme == "Basic" ?
            NSURLAuthenticationMethodHTTPBasic : NSURLAuthenticationMethodHTTPDigest
        let space = scenario.proxy ?
            URLProtectionSpace(proxyHost: url.host!, port: url.port!, type: NSURLProtectionSpaceHTTPProxy,
                               realm: "d04", authenticationMethod: method) :
            URLProtectionSpace(host: url.host!, port: url.port!, protocol: "http", realm: "d04",
                               authenticationMethod: method)
        let field = scenario.proxy ? "Proxy-Authenticate" : "WWW-Authenticate"
        let response = HTTPURLResponse(url: url, statusCode: scenario.proxy ? 407 : 401, httpVersion: "HTTP/1.1",
                                       headerFields: [field: d04ChallengeHeader(scenario.scheme)])!
        delivery.challenge(URLAuthenticationChallenge(protectionSpace: space,
                                                      proposedCredential: scenario.proposed ? d04Credential() : nil,
                                                      previousFailureCount: failures, failureResponse: response,
                                                      error: nil, sender: sender))
    }

    private func finish(_ decision: D04SenderDecision) {
        D04SyntheticProbe.deliveryTimes.withLock { $0.append(.now) }
        if let expected = scenario.expectedDecision, expected != decision.name {
            delivery.finish(error: NSError(domain: "D04BranchMismatch", code: 1))
        } else if decision.name == "cancel" {
            delivery.finish(error: URLError(.cancelled) as NSError)
        } else if scenario.failure {
            delivery.finish(error: URLError(.cannotConnectToHost) as NSError)
        } else {
            let status = decision.name == "use" ? 200 : (scenario.proxy ? 407 : 401)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            delivery.head(response: response)
            delivery.bytes(status == 200 ? "authorized" : "denied")
            delivery.finish()
        }
    }
}

func d04Reset(_ scenario: D04ReplayScenario = D04ReplayScenario()) {
    D04SyntheticProbe.scenario.withLock { $0 = scenario }
    D04SyntheticProbe.forwardingConfiguration.withLock { $0 = nil }
    D04SyntheticProbe.sender.withLock { $0 = nil }
    D04SyntheticProbe.decisions.withLock { $0 = [] }
    D04SyntheticProbe.decisionTimes.withLock { $0 = [] }
    D04SyntheticProbe.deliveryTimes.withLock { $0 = [] }
}
