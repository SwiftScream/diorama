import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
    import Testing

    extension D04ChallengeTests {
        @Test
        func `custom credential choice must return to the sender without live networking`() async throws {
            d04Reset()
            let server = try D03HTTPServer()
            let consumer = D04Consumer(mode: "use")
            let session = d04Session(consumer, synthetic: true)
            defer { session.invalidateAndCancel(); d04Reset() }
            session.dataTask(with: server.url("/must-remain-offline")) { data, response, error in
                consumer.complete(data: data, response: response, error: error)
            }.resume()
            try #require(await d02Eventually {
                server.poll { _ in D03HTTPReply(body: "unexpected-live-response") }
                return consumer.observation.withLock { $0.completions > 0 }
            })
            let result = consumer.observation.withLock { $0 }
            let senderCount = D04SyntheticProbe.decisions.withLock { $0.count }
            print("D04 Linux custom use: challenges=\(result.challenges.count), sender=\(senderCount), " +
                "liveRequests=\(server.requests.count), bodyBytes=\(result.body.count)")
            withKnownLinuxIssue("FN-15: custom challenge credential choice starts native HTTP") {
                #expect(senderCount == 1)
                #expect(server.requests.count == 0)
                #expect(result.body == Data("authorized".utf8))
            }
        }
    }
#endif
