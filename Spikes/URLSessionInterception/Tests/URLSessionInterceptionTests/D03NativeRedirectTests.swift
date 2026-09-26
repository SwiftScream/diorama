import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

@Suite(.serialized)
struct D03NativeRedirectTests {
    @Test
    func `native data delegate receives the refused redirect body`() async throws {
        let server = try D03HTTPServer()
        let consumer = D03RedirectConsumer(mode: "refuse")
        let session = d03Session(delegate: consumer)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: server.url()).resume()
        try #require(await d02Eventually {
            server.poll { _ in D03HTTPReply(status: 302, location: "/final", body: "refused") }
            return consumer.observation.withLock { $0.completions > 0 }
        })
        let result = consumer.observation.withLock { $0 }
        #expect(server.requests.count == 1)
        #expect(result.error == nil)
        #expect(result.response?.statusCode == 302)
        #expect(result.body == Data("refused".utf8))
    }

    @Test(arguments: ["automatic", "follow", "refuse", "modify", "relative", "multiple"])
    func `native redirects expose decisions and preserve each hop`(mode: String) async throws {
        let server = try D03HTTPServer()
        let consumer = D03RedirectConsumer(mode: mode)
        let session = d03Session(delegate: mode == "automatic" ? nil : consumer)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: server.url("/directory/start")) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }.resume()
        try #require(await d02Eventually {
            server.poll { request in
                switch request.target {
                case "/directory/start":
                    D03HTTPReply(status: 302, location: mode == "relative" ? "next" : "/directory/next",
                                 body: "refused")
                case "/directory/next" where mode == "multiple":
                    D03HTTPReply(status: 307, location: "/final", body: "unavailable")
                default: D03HTTPReply()
                }
            }
            return consumer.observation.withLock { $0.completions > 0 }
        })
        let result = consumer.observation.withLock { $0 }
        let targets = server.requests.map(\.target)
        print("D03 native \(mode): targets=\(targets), decisions=\(result.statuses), " +
            "status=\(result.response?.statusCode ?? -1), error=\(String(describing: result.error))")
        #expect(server.sendsSucceeded)
        #expect(result.error == nil)
        #expect(result.completions == 1)
        withKnownLinuxIssue("FN-01: native refused body is overwritten by an empty drain", affected: mode == "refuse") {
            #expect(result.body == Data((mode == "refuse" ? "refused" : "final").utf8))
        }
        #expect(result.response?.statusCode == (mode == "refuse" ? 302 : 200))
        #expect(result.proposals.count == (mode == "automatic" ? 0 : mode == "multiple" ? 2 : 1))
        let expected = switch mode {
        case "refuse": ["/directory/start"]
        case "modify": ["/directory/start", "/directory/modified"]
        case "multiple": ["/directory/start", "/directory/next", "/final"]
        default: ["/directory/start", "/directory/next"]
        }
        withKnownLinuxIssue("FN-12: path-relative redirect resolves at the origin root", affected: mode == "relative") {
            #expect(targets == expected)
        }
        if mode == "modify" {
            #expect(server.requests.last?.headers["x-d03-modified"] == "consumer")
        }
    }

    @Test(arguments: [301, 302, 303, 307, 308], ["automatic", "follow"])
    func `native POST redirect request derivation matches wire bytes`(status: Int, mode: String) async throws {
        let server = try D03HTTPServer()
        let consumer = D03RedirectConsumer()
        let session = d03Session(delegate: mode == "automatic" ? nil : consumer)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: server.url())
        request.httpMethod = "POST"
        request.httpBody = Data("payload".utf8)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        session.dataTask(with: request) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }.resume()
        try #require(await d02Eventually {
            server.poll { request in
                request.target == "/start"
                    ? D03HTTPReply(status: status, location: "/final", body: "redirect") : D03HTTPReply()
            }
            return consumer.observation.withLock { $0.completions > 0 }
        })
        let result = consumer.observation.withLock { $0 }
        print("D03 native POST \(status)/\(mode): " +
            "wire=\(server.requests.map { "\($0.method):\($0.body.count)" }), " +
            "proposed=\(result.proposals.map { "\($0.httpMethod ?? "nil"):\($0.httpBody?.count ?? -1)" })")
        try #require(server.requests.count == 2)
        #expect(server.requests[0].body == Data("payload".utf8))
        #expect(result.error == nil)
        #expect(result.body == Data("final".utf8))
        let preservesBody = status == 307 || status == 308
        #expect(server.requests[1].method == (preservesBody ? "POST" : "GET"))
        withKnownLinuxIssue("FN-13: native redirect clears the known request body", affected: preservesBody) {
            #expect(server.requests[1].body == (preservesBody ? Data("payload".utf8) : Data()))
        }
        if mode == "follow" {
            #expect(result.proposals.first?.httpMethod == (preservesBody ? "POST" : "GET"))
        }
    }

    @Test
    func `native cross-host redirect prepares credentials`() async throws {
        let source = try D03HTTPServer()
        let target = try D03HTTPServer()
        let consumer = D03RedirectConsumer()
        let session = d03Session(delegate: consumer)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: source.url())
        request.setValue("Bearer synthetic-d03", forHTTPHeaderField: "Authorization")
        request.setValue("synthetic=d03", forHTTPHeaderField: "Cookie")
        request.setValue("retained", forHTTPHeaderField: "X-D03-Public")
        session.dataTask(with: request) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }.resume()
        try #require(await d02Eventually {
            source.poll { _ in
                D03HTTPReply(status: 302, location: target.url("/final", host: "localhost").absoluteString)
            }
            target.poll { _ in D03HTTPReply() }
            return consumer.observation.withLock { $0.completions > 0 }
        })
        let result = consumer.observation.withLock { $0 }
        try #require(source.requests.count == 1 && target.requests.count == 1)
        let proposedAuth = result.proposals.first?.value(forHTTPHeaderField: "Authorization") != nil
        print("D03 credentials: proposedAuth=\(proposedAuth), " +
            "wireAuth=\(target.requests[0].headers["authorization"] != nil), " +
            "wireCookie=\(target.requests[0].headers["cookie"] != nil)")
        #expect(result.error == nil)
        #expect(target.requests[0].headers["x-d03-public"] == "retained")
        withKnownLinuxIssue("FN-14: explicit Authorization survives a cross-host native redirect") {
            #expect(target.requests[0].headers["authorization"] == nil)
        }
    }

    @Test
    func `native redirect loop terminates at its limit`() async throws {
        let server = try D03HTTPServer()
        let consumer = D03RedirectConsumer()
        let session = d03Session(delegate: consumer)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: server.url()) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }.resume()
        try #require(await d02Eventually {
            server.poll { _ in D03HTTPReply(status: 302, location: "/start") }
            return consumer.observation.withLock { $0.completions > 0 }
        })
        let result = consumer.observation.withLock { $0 }
        print("D03 native loop: requests=\(server.requests.count), decisions=\(result.proposals.count)")
        #expect(result.error?.domain == NSURLErrorDomain)
        #expect(result.error?.code == URLError.httpTooManyRedirects.rawValue)
        #expect(server.requests.count == 21)
    }

    @Test(arguments: [false, true])
    func `native unanswered redirect gates delivery and permits cancellation`(cancel: Bool) async throws {
        let server = try D03HTTPServer()
        let consumer = D03RedirectConsumer(mode: "pending")
        let session = d03Session(delegate: consumer)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: server.url())
        task.resume()
        try #require(await d02Eventually {
            server.poll { _ in D03HTTPReply(status: 302, location: "/final") }
            return consumer.observation.withLock { $0.pending != nil }
        })
        // An observed pending decision is the barrier; the wait tests absence
        // of premature work, not a timeout-based claim of native quiescence.
        try await Task.sleep(for: .milliseconds(150))
        #expect(server.requests.count == 1)
        #expect(consumer.observation.withLock { $0.body.isEmpty && $0.completions == 0 })
        if cancel {
            task.cancel()
        } else {
            consumer.decide(consumer.observation.withLock { $0.proposals.last })
        }
        try #require(await d02Eventually {
            server.poll { _ in D03HTTPReply() }
            return consumer.observation.withLock { $0.completions > 0 }
        })
        let result = consumer.observation.withLock { $0 }
        #expect(result.error?.code == (cancel ? URLError.cancelled.rawValue : nil))
        #expect(server.requests.count == (cancel ? 1 : 2))
        // Do not invoke a retained native decision after cancellation; that is
        // a separate late-callback/lifetime question for D05.
        consumer.observation.withLock { $0.pending = nil }
    }
}
