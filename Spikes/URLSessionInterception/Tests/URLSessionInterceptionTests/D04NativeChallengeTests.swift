import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

@Suite(.serialized)
struct D04NativeChallengeTests {
    @Test(arguments: ["Basic", "Digest"], ["use", "default", "reject", "cancel", "repeat"])
    func `native HTTP authentication exposes challenge continuations`(scheme: String, mode: String) async throws {
        let server = try D03HTTPServer()
        let consumer = D04Consumer(mode: mode)
        let session = d04Session(consumer)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: server.url("/authentication")) { data, response, error in
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
        print("D04 native \(scheme)/\(mode): requests=\(server.requests.count), " +
            "failures=\(result.challenges.map(\.previousFailures)), status=\(result.status ?? -1), " +
            "bodyBytes=\(result.body.count), error=\(result.errorDomain ?? "nil")/\(result.errorCode ?? 0)")
        #expect(server.sendsSucceeded)
        #if canImport(FoundationNetworking)
            if scheme == "Digest" {
                // Owner-approved native Digest exception. A changed native
                // baseline requires capability review, not silent enablement.
                #expect(result.challenges.count == 0)
                #expect(result.status == 401)
                #expect(result.errorDomain == nil)
                #expect(result.body == Data("denied".utf8))
                #expect(server.requests.count == 1)
                return
            }
        #endif
        #expect(result.challenges.count == (mode == "repeat" ? 3 : 1))
        #expect(result.challenges.map(\.previousFailures) == (mode == "repeat" ? [0, 1, 2] : [0]))
        #expect(result.challenges.allSatisfy { $0.responseStatus == 401 && $0.realm == "d04" })
        if mode == "use" {
            #expect(result.errorDomain == nil)
            #expect(result.status == 200)
            #expect(result.body == Data("authorized".utf8))
            #expect(server.requests.count == 2)
        } else if mode == "cancel" {
            #expect(result.errorCode == URLError.cancelled.rawValue)
        } else {
            #if canImport(FoundationNetworking)
                if mode == "reject" {
                    #expect(result.errorCode == URLError.cancelled.rawValue); return
                }
            #endif
            d04CheckOutcome(result, mode: mode)
        }
    }
}
