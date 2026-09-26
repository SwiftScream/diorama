import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

extension D04ChallengeTests {
    @Test(arguments: ["unsupported-method", "missing-response"])
    func `unsupported native challenges fail before consumer presentation`(variant: String) async throws {
        d04Reset()
        let listener = try D02LoopbackListener()
        let consumer = D04Consumer(mode: "use")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [D04UnsupportedProtocol.self]
        let session = d04ForwardingSession(consumer, configuration: configuration)
        defer { session.invalidateAndCancel(); d04Reset() }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/\(variant)"))
        session.dataTask(with: url) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }.resume()
        try #require(await d02Eventually {
            listener.poll()
            return consumer.observation.withLock { $0.completions > 0 }
        })
        let result = consumer.observation.withLock { $0 }
        #expect(result.errorDomain == "D04UnsupportedAuthenticationChallenge")
        #expect(result.completions == 1)
        #expect(result.challenges.count == 0)
        #expect(result.body.count == 0)
        #expect(listener.connections == 0)
    }
}

/// Injects an unsupported live dependency through the consumer's preserved
/// protocol list. It does not construct trust, identity, or certificate objects.
private final class D04UnsupportedProtocol: URLProtocol {
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
        let url = request.url!
        let missing = url.path == "/missing-response"
        let method = missing ? NSURLAuthenticationMethodHTTPBasic : "D04UnsupportedMethod"
        let space = URLProtectionSpace(host: url.host!, port: url.port!, protocol: "http",
                                       realm: "d04", authenticationMethod: method)
        let response = missing ? nil :
            HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                                                   previousFailureCount: 0, failureResponse: response,
                                                   error: nil, sender: D04Sender { _ in })
        client?.urlProtocol(self, didReceive: challenge)
    }

    override func stopLoading() {}
}
