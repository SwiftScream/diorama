import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

extension D04ChallengeTests {
    @Test(.enabled(if: d04CanBridgeChallenges, "FN-15: custom authentication can escape to native HTTP"),
          arguments: ["Basic", "Digest"], ["use", "default", "reject", "cancel", "repeat", "failure", "mismatch"])
    func `replay challenge metadata and continuations stay offline`(scheme: String, mode: String) async throws {
        d04Reset(D04ReplayScenario(scheme: scheme, proxy: false, repeatCount: mode == "repeat" ? 2 : 0,
                                   proposed: true, failure: mode == "failure",
                                   expectedDecision: mode == "mismatch" ? "reject" : nil))
        let listener = try D02LoopbackListener()
        let consumer = D04Consumer(mode: ["failure", "mismatch"].contains(mode) ? "use" : mode)
        let session = d04Session(consumer, synthetic: true, bridge: true)
        defer { session.invalidateAndCancel(); d04Reset() }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/replay"))
        session.dataTask(with: url) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }.resume()
        try #require(await d02Eventually {
            listener.poll()
            return consumer.observation.withLock { $0.completions > 0 }
        })
        let result = consumer.observation.withLock { $0 }
        #expect(listener.connections == 0)
        #expect(result.completions == 1)
        #expect(result.challenges.map(\.previousFailures) == (mode == "repeat" ? [0, 1, 2] : [0]))
        #expect(result.challenges.allSatisfy { $0.proposed?.user == "d04-user" && $0.proposed?.hasPassword == true })
        #expect(result.challenges.allSatisfy { $0.responseStatus == 401 && $0.port == Int(listener.port) })
        let bytes = try JSONEncoder().encode(result.challenges)
        let encoded = try #require(String(bytes: bytes, encoding: .utf8))
        let leaksPassword = encoded.contains("d04-in-memory-only-passphrase")
        #expect(!leaksPassword)
        d04CheckOutcome(result, mode: mode)
    }

    @Test(.enabled(if: d04CanBridgeChallenges, "FN-15: custom authentication can escape to native HTTP"),
          arguments: ["delegate", "completion", "async", "asyncDelegate"])
    func `proxy challenge replay preserves consumer presentation`(presentation: String) async throws {
        d04Reset(D04ReplayScenario(proxy: true))
        let listener = try D02LoopbackListener()
        let consumer = D04Consumer(mode: "use")
        let session = d04Session(consumer, synthetic: true, bridge: true)
        defer { session.invalidateAndCancel(); d04Reset() }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/proxy-replay"))
        let operation = Task {
            do {
                if presentation == "delegate" {
                    session.dataTask(with: url).resume()
                } else if presentation == "completion" {
                    session.dataTask(with: url) { data, response, error in
                        consumer.complete(data: data, response: response, error: error)
                    }.resume()
                } else {
                    let supplied = presentation == "asyncDelegate" ? consumer : nil
                    let (data, response) = try await session.data(from: url, delegate: supplied)
                    consumer.complete(data: data, response: response, error: nil)
                }
            } catch { consumer.complete(data: nil, response: nil, error: error) }
        }
        defer { operation.cancel() }
        try #require(await d02Eventually {
            listener.poll()
            return consumer.observation.withLock { $0.completions > 0 }
        })
        let result = consumer.observation.withLock { $0 }
        #expect(listener.connections == 0)
        #expect(result.challenges.first?.isProxy == true)
        #expect(result.challenges.first?.proxyType == NSURLProtectionSpaceHTTPProxy)
        #expect(result.challenges.first?.responseStatus == 407)
        d04CheckOutcome(result, mode: "use")
    }

    @Test(.enabled(if: d04CanBridgeChallenges, "FN-15: custom authentication can escape to native HTTP"),
          arguments: ["answer", "taskCancel"])
    func `pending challenge gates continuation and starts delay after answer`(mode: String) async throws {
        d04Reset(D04ReplayScenario(delay: .milliseconds(30)))
        let listener = try D02LoopbackListener()
        let consumer = D04Consumer(mode: "pending")
        let session = d04Session(consumer, synthetic: true, bridge: true)
        defer { session.invalidateAndCancel(); d04Reset() }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/pending"))
        let task = session.dataTask(with: url) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }
        task.resume()
        try #require(await d02Eventually { consumer.observation.withLock { $0.pending != nil } })
        try await Task.sleep(for: .milliseconds(60))
        #expect(consumer.observation.withLock { $0.completions } == 0)
        #expect(D04SyntheticProbe.decisions.withLock { $0.count } == 0)
        if mode == "answer" {
            consumer.answer(.useCredential, credential: d04Credential())
        } else {
            task.cancel()
        }
        try #require(await d02Eventually { consumer.observation.withLock { $0.completions > 0 } })
        listener.poll()
        #expect(listener.connections == 0)
        let result = consumer.observation.withLock { $0 }
        if mode == "answer" {
            let answer = try #require(D04SyntheticProbe.decisionTimes.withLock { $0.first })
            let delivery = try #require(D04SyntheticProbe.deliveryTimes.withLock { $0.first })
            #expect(answer.duration(to: delivery) >= .milliseconds(30))
            d04CheckOutcome(result, mode: "use")
        } else {
            #expect(result.errorCode == URLError.cancelled.rawValue)
            #expect(D04SyntheticProbe.decisions.withLock { $0.count } == 0)
            consumer.observation.withLock { $0.pending = nil }
        }
    }
}

func d04CheckOutcome(_ result: D04Observation, mode: String) {
    switch mode {
    case "cancel": #expect(result.errorCode == URLError.cancelled.rawValue)
    case "failure": #expect(result.errorCode == URLError.cannotConnectToHost.rawValue)
    case "mismatch": #expect(result.errorDomain == "D04BranchMismatch")
    default:
        #expect(result.errorDomain == nil)
        #expect(result.status == (mode == "use" ? 200 : 401))
        #expect(result.body == Data((mode == "use" ? "authorized" : "denied").utf8))
    }
}
