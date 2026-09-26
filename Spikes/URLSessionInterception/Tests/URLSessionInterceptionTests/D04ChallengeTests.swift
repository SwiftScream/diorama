import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

var d04CanBridgeChallenges: Bool {
    #if canImport(FoundationNetworking)
        ProcessInfo.processInfo.environment["DIORAMA_VERIFY_FOUNDATION_FIXES"] == "1"
    #else
        true
    #endif
}

var d04ProbeSender: Bool {
    ProcessInfo.processInfo.environment["DIORAMA_D04_PROBE_SENDER"] == "1"
}

@Suite(.serialized)
struct D04ChallengeTests {
    @Test(.enabled(if: d04CanBridgeChallenges, "FN-15: challenge use escapes the custom protocol on Linux"),
          arguments: d04ProbeSender ? [false, true] : [true])
    func `forwarded native challenge returns a credential decision`(observe: Bool) async throws {
        d04Reset()
        let server = try D03HTTPServer()
        let consumer = D04Consumer(mode: "use")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.protocolClasses = [D04ForwardingProtocol.self]
        let session = URLSession(configuration: configuration,
                                 delegate: observe ? D04DelegateProxy(consumer) : consumer, delegateQueue: nil)
        defer { session.invalidateAndCancel(); d04Reset() }
        session.dataTask(with: server.url("/forward")) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }.resume()
        let completed = await d02Eventually {
            server.poll { request in
                request.headers["authorization"] == nil ?
                    D03HTTPReply(status: 401, body: "denied", headers: ["WWW-Authenticate": "Basic realm=\"d04\""]) :
                    D03HTTPReply(body: "authorized")
            }
            return consumer.observation.withLock { $0.completions > 0 }
        }
        let result = consumer.observation.withLock { $0 }
        print("D04 forwarded observer=\(observe): completed=\(completed), challenges=\(result.challenges.count), " +
            "sender=\(D04SyntheticProbe.decisions.withLock { $0.count }), requests=\(server.requests.count), " +
            "status=\(result.status ?? -1), error=\(result.errorDomain ?? "nil")/\(result.errorCode ?? 0)")
        #expect(completed)
        #expect(result.body == Data("authorized".utf8))
        #expect(server.requests.count == 2)
    }

    @Test(.enabled(if: d04ProbeSender && d04CanBridgeChallenges,
                   "Opt-in investigation of the unsuccessful native-sender approach"),
          arguments: ["use", "default", "reject", "cancel"])
    func `custom challenge decisions return to the protocol sender`(mode: String) async throws {
        d04Reset()
        let listener = try D02LoopbackListener()
        let consumer = D04Consumer(mode: mode)
        let session = d04Session(consumer, synthetic: true)
        defer { session.invalidateAndCancel(); d04Reset() }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/challenge"))
        let task = session.dataTask(with: url) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }
        task.resume()
        let completed = await d02Eventually {
            listener.poll()
            return consumer.observation.withLock { $0.completions > 0 }
        }
        let result = consumer.observation.withLock { $0 }
        let decisions = D04SyntheticProbe.decisions.withLock { $0 }
        print("D04 synthetic \(mode): challenges=\(result.challenges.count), " +
            "sender=\(decisions.map(\.name)), status=\(result.status ?? -1), " +
            "error=\(result.errorDomain ?? "nil")/\(result.errorCode ?? 0), connections=\(listener.connections)")
        #expect(completed)
        #expect(result.challenges.count == 1)
        #expect(decisions.count == 1)
        #expect(listener.connections == 0)
    }

    @Test(.enabled(if: d04CanBridgeChallenges, "FN-15: challenge use escapes the custom protocol on Linux"),
          arguments: ["use", "default", "reject", "cancel"])
    func `delegate observation resumes a synthetic challenge continuation`(mode: String) async throws {
        d04Reset()
        let listener = try D02LoopbackListener()
        let consumer = D04Consumer(mode: mode)
        let session = d04Session(consumer, synthetic: true, bridge: true)
        defer { session.invalidateAndCancel(); d04Reset() }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/challenge"))
        session.dataTask(with: url) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }.resume()
        let completed = await d02Eventually {
            listener.poll()
            return consumer.observation.withLock { $0.completions > 0 }
        }
        let result = consumer.observation.withLock { $0 }
        print("D04 observed \(mode): completed=\(completed), status=\(result.status ?? -1), " +
            "bodyBytes=\(result.body.count), error=\(result.errorDomain ?? "nil")/\(result.errorCode ?? 0), " +
            "connections=\(listener.connections)")
        #expect(completed)
        #expect(listener.connections == 0)
        #expect(result.challenges.count == 1)
    }
}
