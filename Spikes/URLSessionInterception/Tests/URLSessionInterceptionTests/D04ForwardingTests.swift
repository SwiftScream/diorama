import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

extension D04ChallengeTests {
    @Test(.enabled(if: d04CanBridgeChallenges, "FN-15: custom authentication can escape to native HTTP"),
          arguments: ["Basic", "Digest"], ["use", "default", "reject", "cancel", "repeat"])
    func `private forwarding preserves native authentication continuations`(scheme: String, mode: String) async throws {
        d04Reset()
        let server = try D03HTTPServer()
        let consumer = D04Consumer(mode: mode)
        let session = d04ForwardingSession(consumer)
        defer { session.invalidateAndCancel(); d04Reset() }
        session.dataTask(with: server.url("/forward")) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }.resume()
        try #require(await d02Eventually {
            server.poll { request in
                if mode != "repeat", request.headers["authorization"]?.hasPrefix(scheme + " ") == true {
                    return D03HTTPReply(body: "authorized")
                }
                return D03HTTPReply(status: 401, body: "denied",
                                    headers: ["WWW-Authenticate": d04ChallengeHeader(scheme)])
            }
            return consumer.observation.withLock { $0.completions > 0 }
        })
        let result = consumer.observation.withLock { $0 }
        #expect(result.completions == 1)
        #expect(result.challenges.map(\.previousFailures) == (mode == "repeat" ? [0, 1, 2] : [0]))
        #expect(D04SyntheticProbe.decisions.withLock { $0.count } == result.challenges.count)
        #expect(server.sendsSucceeded)
        d04CheckOutcome(result, mode: mode)
    }

    @Test(arguments: d04CanBridgeChallenges ? [false, true] : [false])
    func `native and forwarded challenges wait for consumer decisions`(forwarded: Bool) async throws {
        d04Reset()
        let server = try D03HTTPServer()
        let consumer = D04Consumer(mode: "pending")
        let session = forwarded ? d04ForwardingSession(consumer) : d04Session(consumer)
        defer { session.invalidateAndCancel(); d04Reset() }
        let task = session.dataTask(with: server.url("/pending")) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }
        task.resume()
        try #require(await d02Eventually {
            server.poll { _ in
                D03HTTPReply(status: 401, body: "denied", headers: ["WWW-Authenticate": d04ChallengeHeader("Basic")])
            }
            return consumer.observation.withLock { $0.pending != nil }
        })
        try await Task.sleep(for: .milliseconds(40))
        #expect(consumer.observation.withLock { $0.completions } == 0)
        #expect(server.requests.count == 1)
        consumer.answer(.cancelAuthenticationChallenge)
        try #require(await d02Eventually { consumer.observation.withLock { $0.completions > 0 } })
        #expect(consumer.observation.withLock { $0.errorCode } == URLError.cancelled.rawValue)
        #expect(server.requests.count == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIORAMA_D04_HTTPS"] == "1",
                   "Opt-in external HTTPS smoke; deterministic loopback tests remain the default gate"),
          arguments: [false, true], ["valid", "untrusted"])
    func `ordinary HTTPS uses native default trust handling`(forwarded: Bool, trust: String) async throws {
        d04Reset()
        let consumer = D04Consumer(mode: "default")
        let session = forwarded ? d04ForwardingSession(consumer) : d04Session(consumer)
        defer { session.invalidateAndCancel(); d04Reset() }
        let endpoint = trust == "valid" ? "https://example.com/" : "https://self-signed.badssl.com/"
        let url = try #require(URL(string: endpoint))
        session.dataTask(with: url).resume()
        try #require(await d02Eventually { consumer.observation.withLock { $0.completions > 0 } })
        let result = consumer.observation.withLock { $0 }
        print("D04 HTTPS forwarded=\(forwarded) trust=\(trust): status=\(result.status ?? -1), " +
            "error=\(result.errorDomain ?? "nil")/\(result.errorCode ?? 0)")
        #expect(result.challenges.count == 0)
        #expect(result.sessionChallenges.count == 0)
        if trust == "valid" {
            #expect(result.errorDomain == nil)
            #expect(result.status == 200)
            #expect(result.body.count > 0)
        } else {
            #expect(result.errorDomain == NSURLErrorDomain)
            #if canImport(FoundationNetworking)
                // FN-18: native TLS verification fails correctly but loses its
                // specific URL error mapping. Forwarding preserves that code.
                #expect(result.errorCode == URLError.unknown.rawValue)
                #expect(result.certificateFailure)
            #else
                #expect(result.errorCode == URLError.serverCertificateUntrusted.rawValue)
            #endif
            #expect(result.body.count == 0)
        }
    }
}
