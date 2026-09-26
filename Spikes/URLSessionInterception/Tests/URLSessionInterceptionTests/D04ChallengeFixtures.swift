import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization

/// Only this explicitly selected metadata can enter evidence or diagnostics.
/// Credentials remain transient native values; the fixture never describes them.
struct D04CredentialMetadata: Codable, Sendable {
    let user: String?
    let hasPassword: Bool
    let persistence: UInt

    init(_ credential: URLCredential) {
        user = credential.user
        hasPassword = credential.hasPassword
        persistence = credential.persistence.rawValue
    }
}

struct D04ChallengeMetadata: Codable, Sendable {
    let host: String
    let port: Int
    let transport: String?
    let realm: String?
    let isProxy: Bool
    let proxyType: String?
    let method: String
    let previousFailures: Int
    let responseStatus: Int?
    let proposed: D04CredentialMetadata?

    init(_ challenge: URLAuthenticationChallenge) {
        let space = challenge.protectionSpace
        host = space.host
        port = space.port
        transport = space.protocol
        realm = space.realm
        isProxy = space.isProxy()
        proxyType = space.proxyType
        method = space.authenticationMethod
        previousFailures = challenge.previousFailureCount
        responseStatus = (challenge.failureResponse as? HTTPURLResponse)?.statusCode
        proposed = challenge.proposedCredential.map(D04CredentialMetadata.init)
    }
}

struct D04Observation: Sendable {
    var challenges: [D04ChallengeMetadata] = []
    var sessionChallenges: [D04ChallengeMetadata] = []
    var body = Data()
    var status: Int?
    var errorDomain: String?
    var errorCode: Int?
    var certificateFailure = false
    var completions = 0
    var pending: (@Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)?
}

func d04Credential() -> URLCredential {
    // Synthetic test input, never a real credential. Do not print native
    // credentials, Authorization values, or the result of password extraction.
    URLCredential(user: "d04-user", password: "d04-in-memory-only-passphrase", persistence: .none)
}

final class D04Consumer: NSObject, URLSessionDataDelegate {
    let mode: String
    let observation = Mutex(D04Observation())

    init(mode: String) {
        self.mode = mode
    }

    func urlSession(_: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping D04Answer)
    {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        observation.withLock { $0.sessionChallenges.append(D04ChallengeMetadata(challenge)) }
        completionHandler(mode == "use" ? .useCredential : .performDefaultHandling,
                          mode == "use" ? d04Credential() : nil)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping D04Answer)
    {
        observation.withLock { $0.challenges.append(D04ChallengeMetadata(challenge)) }
        let answer = completionHandler
        switch mode {
        case "use": answer(.useCredential, d04Credential())
        case "repeat":
            answer(challenge.previousFailureCount < 2 ? .useCredential : .performDefaultHandling,
                   challenge.previousFailureCount < 2 ? d04Credential() : nil)
        case "reject": answer(.rejectProtectionSpace, nil)
        case "cancel": answer(.cancelAuthenticationChallenge, nil)
        case "pending": observation.withLock { $0.pending = answer }
        default: answer(.performDefaultHandling, nil)
        }
    }

    func answer(_ disposition: URLSession.AuthChallengeDisposition, credential: URLCredential? = nil) {
        let pending = observation.withLock { state in
            defer { state.pending = nil }
            return state.pending
        }
        pending?(disposition, credential)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        observation.withLock { $0.status = (response as? HTTPURLResponse)?.statusCode }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        observation.withLock { $0.body.append(data) }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        complete(data: nil, response: nil, error: error)
    }

    func complete(data: Data?, response: URLResponse?, error: (any Error)?) {
        observation.withLock {
            if let data {
                $0.body = data
            }
            if let response {
                $0.status = (response as? HTTPURLResponse)?.statusCode
            }
            $0.errorDomain = (error as NSError?)?.domain
            $0.errorCode = (error as NSError?)?.code
            // Classify the opt-in TLS control without storing or rendering a
            // native error description. This Boolean is not snapshot data.
            $0.certificateFailure = (error as NSError?)?.localizedDescription
                .localizedCaseInsensitiveContains("certificate") == true
            $0.completions += 1
        }
    }
}

struct D04SenderDecision: Sendable {
    let name: String
    let credential: D04CredentialMetadata?
}

final class D04Sender: NSObject, URLAuthenticationChallengeSender {
    let answer: @Sendable (D04SenderDecision) -> Void
    let nativeAnswer: (@Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)?
    private let answered = Mutex(false)

    func resolve(_ disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?) {
        guard answered.withLock({ used in
            defer { used = true }
            return !used
        }) else { return }
        let name = switch disposition {
        case .useCredential: "use"
        case .performDefaultHandling: "default"
        case .rejectProtectionSpace: "reject"
        case .cancelAuthenticationChallenge: "cancel"
        @unknown default: "unknown"
        }
        answer(D04SenderDecision(name: name, credential: credential.map(D04CredentialMetadata.init)))
        nativeAnswer?(disposition, credential)
    }

    init(nativeAnswer: (@Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)? = nil,
         answer: @escaping @Sendable (D04SenderDecision) -> Void)
    {
        self.nativeAnswer = nativeAnswer
        self.answer = answer
    }

    func use(_ credential: URLCredential, for _: URLAuthenticationChallenge) {
        resolve(.useCredential, credential: credential)
    }

    func continueWithoutCredential(for _: URLAuthenticationChallenge) {
        resolve(.performDefaultHandling, credential: nil)
    }

    func cancel(_: URLAuthenticationChallenge) {
        resolve(.cancelAuthenticationChallenge, credential: nil)
    }

    func performDefaultHandling(for _: URLAuthenticationChallenge) {
        resolve(.performDefaultHandling, credential: nil)
    }

    func rejectProtectionSpaceAndContinue(with _: URLAuthenticationChallenge) {
        resolve(.rejectProtectionSpace, credential: nil)
    }
}

enum D04SyntheticProbe {
    static let scenario = Mutex(D04ReplayScenario())
    static let forwardingConfiguration = Mutex<URLSessionConfiguration?>(nil)
    static let decisionTimes = Mutex<[ContinuousClock.Instant]>([])
    static let deliveryTimes = Mutex<[ContinuousClock.Instant]>([])
    static let decisions = Mutex<[D04SenderDecision]>([])
    static let sender = Mutex<D04Sender?>(nil)
}

final class D04ChallengeProtocol: URLProtocol {
    private let delivery = Mutex<D02ControlledDelivery?>(nil)

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canInit(with _: URLSessionTask) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let delivery = D02ControlledDelivery(self)
        self.delivery.withLock { $0 = delivery }
        D04ReplayFlow(delivery: delivery, url: request.url!,
                      scenario: D04SyntheticProbe.scenario.withLock { $0 }).present(failures: 0)
    }

    override func stopLoading() {
        delivery.withLock { $0 }?.stop()
    }
}

func d04Session(_ consumer: D04Consumer, synthetic: Bool = false, bridge: Bool = false) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = d02WatchdogSeconds
    if synthetic {
        configuration.protocolClasses = [D04ChallengeProtocol.self]
    }
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    return URLSession(configuration: configuration, delegate: bridge ? D04DelegateProxy(consumer) : consumer,
                      delegateQueue: queue)
}
