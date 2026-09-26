import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

extension D04ChallengeTests {
    @Test(arguments: ["Basic", "Digest"], d04CanBridgeChallenges ?
        ["http", "https", "forward-http", "forward-https"] : ["http", "https"])
    func `native proxy authentication presents a response owned challenge`(scheme: String,
                                                                           variant: String) async throws
    {
        d04Reset()
        let transport = variant.hasSuffix("https") ? "https" : "http"
        let origin = try D03HTTPServer()
        let proxy = try D03HTTPServer()
        let consumer = D04Consumer(mode: "use")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = try [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": #require(proxy.url("/").port),
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": #require(proxy.url("/").port),
            "ExceptionsList": [String](), "ExcludeSimpleHostnames": 0,
        ]
        let session = variant.hasPrefix("forward") ? d04ForwardingSession(consumer, configuration: configuration) :
            URLSession(configuration: configuration, delegate: consumer, delegateQueue: nil)
        defer { session.invalidateAndCancel(); d04Reset() }
        // Foundation bypasses HTTP proxy settings for loopback destinations.
        // The reserved .invalid name has no reachable origin; the local proxy
        // itself supplies the response and does not forward to that hostname.
        let url = try #require(URL(string: "\(transport)://d04.invalid:\(origin.url("/").port!)/proxy"))
        session.dataTask(with: url) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }.resume()
        try #require(await d02Eventually {
            origin.poll { _ in D03HTTPReply(body: "bypassed-proxy") }
            proxy.poll { request in
                if request.headers["proxy-authorization"]?.hasPrefix(scheme + " ") == true {
                    // A deterministic failure after authentication avoids
                    // opening an origin connection or implementing TLS here.
                    return D03HTTPReply(status: 502, body: "proxy-stopped-after-auth")
                }
                return D03HTTPReply(status: 407, body: "denied",
                                    headers: ["Proxy-Authenticate": d04ChallengeHeader(scheme)], keepAlive: true)
            }
            return consumer.observation.withLock { $0.completions > 0 }
        })
        let result = consumer.observation.withLock { $0 }
        print("D04 proxy \(scheme)/\(variant): proxyRequests=\(proxy.requests.count), " +
            "originRequests=\(origin.requests.count), " +
            "taskChallenges=\(result.challenges.count), sessionChallenges=\(result.sessionChallenges.count), " +
            "status=\(result.status ?? -1)")
        #expect(origin.requests.count == 0)
        d04CheckProxyResult(result, transport: transport, proxy: proxy)
    }
}

func d04ChallengeHeader(_ scheme: String) -> String {
    scheme == "Basic" ? "Basic realm=\"d04\"" :
        "Digest realm=\"d04\", nonce=\"d04-fixed-nonce\", algorithm=MD5, qop=\"auth\""
}

private func d04CheckProxyResult(_ result: D04Observation, transport: String, proxy: D03HTTPServer) {
    withKnownLinuxIssue("FN-17: connectionProxyDictionary does not route to the configured proxy") {
        if transport == "http" {
            #expect(result.challenges.count == 0)
            #expect(result.status == 407)
            #expect(result.body == Data("denied".utf8))
        } else {
            #expect(result.challenges.count == 1)
            #expect(result.challenges.first?.responseStatus == 407)
            #expect(result.challenges.first?.isProxy == true)
            #expect(result.challenges.first?.port == proxy.url("/").port)
            let usedCredential = proxy.requests.contains { $0.headers["proxy-authorization"] != nil }
            #expect(usedCredential)
            #expect(result.errorDomain != nil)
        }
    }
}
