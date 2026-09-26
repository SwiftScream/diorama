import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

extension D03RedirectTests {
    @Test(arguments: [301, 302, 303, 307, 308], ["automatic", "follow", "refuse", "modify", "modifyBody"])
    func `forwarding retains native redirect decisions and body derivation`(status: Int, mode: String) async throws {
        D03RedirectProbe.reset()
        let server = try D03HTTPServer()
        let consumer = D03RedirectConsumer(mode: mode)
        let session = d03Session(delegate: mode == "automatic" ? nil : consumer, intercepted: true)
        D03RedirectProbe.routes.withLock { $0 = [D03Route(session: session, name: "forward", scenario: "forward")] }
        installForwardingDecisionObservation(consumer)
        defer {
            session.invalidateAndCancel()
            D03RedirectProbe.reset()
        }
        var request = URLRequest(url: server.url())
        request.httpMethod = "POST"
        request.httpBody = Data("payload".utf8)
        let task = session.dataTask(with: request) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }
        task.resume()
        try #require(await d02Eventually {
            server.poll { request in
                request.target == "/start"
                    ? D03HTTPReply(status: status, location: "/final", body: "refused") : D03HTTPReply()
            }
            return consumer.observation.withLock { $0.completions > 0 }
        })
        let result = consumer.observation.withLock { $0 }
        let visits = D03RedirectProbe.visits.withLock { $0 }
        print("D03 forwarded \(status)/\(mode): wire=\(server.requests.map { "\($0.method):\($0.body.count)" }), " +
            "visits=\(visits.count), status=\(result.response?.statusCode ?? -1), " +
            "error=\(String(describing: result.error))")
        #expect(result.error == nil)
        #expect(result.body == Data((mode == "refuse" ? "refused" : "final").utf8))
        #expect(result.response?.statusCode == (mode == "refuse" ? status : 200))
        #expect(result.proposals.count == (mode == "automatic" ? 0 : 1))
        #expect(server.requests.count == (mode == "refuse" ? 1 : 2))
        #expect(visits.count == server.requests.count)
        #expect(Set(visits.map(\.operation)).count == 1)
        #expect(visits.allSatisfy { $0.task == ObjectIdentifier(task) && $0.owner == "forward" })
        #expect(server.requests[0].body == Data("payload".utf8))
        if mode != "refuse" {
            let preservesBody = status == 307 || status == 308 || mode == "modifyBody"
            #expect(server.requests.last?.method == (preservesBody ? "POST" : "GET"))
            let expectedBody = mode == "modifyBody" ? Data("changed".utf8) :
                preservesBody ? Data("payload".utf8) : Data()
            #expect(server.requests.last?.body == expectedBody)
            #expect(server.requests.last?.target == (mode.hasPrefix("modify") ? "/modified" : "/final"))
        }
        #expect(server.sendsSucceeded)
    }

    @Test(arguments: ["relative", "multiple", "crossHost"])
    func `forwarding preserves native destinations and cross-host preparation`(mode: String) async throws {
        D03RedirectProbe.reset()
        let source = try D03HTTPServer()
        let target = try D03HTTPServer()
        let targetURL = target.url("/final", host: "localhost")
        let consumer = D03RedirectConsumer()
        let session = d03Session(delegate: consumer, intercepted: true)
        D03RedirectProbe.routes.withLock { $0 = [D03Route(session: session, name: mode, scenario: "forward")] }
        defer {
            session.invalidateAndCancel()
            D03RedirectProbe.reset()
        }
        var request = URLRequest(url: source.url("/directory/start"))
        request.setValue("Bearer synthetic-d03", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: request)
        task.resume()
        try #require(await d02Eventually {
            source.poll { request in
                switch request.target {
                case "/directory/start":
                    D03HTTPReply(status: 302, location: mode == "crossHost" ? targetURL.absoluteString : "next")
                case "/directory/next" where mode == "multiple":
                    D03HTTPReply(status: 307, location: "/final")
                default: D03HTTPReply()
                }
            }
            target.poll { _ in D03HTTPReply() }
            return consumer.observation.withLock { $0.completions > 0 }
        })
        let result = consumer.observation.withLock { $0 }
        let operation = try #require(D03RedirectProbe.operations.withLock { $0[ObjectIdentifier(task)] })
        let proposals = operation.redirects.withLock { $0 }
        #expect(result.error == nil)
        #expect(result.body == Data("final".utf8))
        #expect(proposals.count == (mode == "multiple" ? 2 : 1))
        #expect(result.proposals.map(\.url) == proposals.map(\.url))
        if mode == "crossHost" {
            #expect(source.requests.count == 1 && target.requests.count == 1)
            #expect(proposals.first?.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(target.requests.first?.headers["authorization"] == nil)
        } else {
            #expect(source.requests.map(\.target) == (mode == "multiple"
                    ? ["/directory/start", "/directory/next", "/final"] : ["/directory/start", "/directory/next"]))
            #expect(target.requests.isEmpty)
        }
        let visits = D03RedirectProbe.visits.withLock { $0 }
        #expect(visits.count == source.requests.count + target.requests.count)
        #expect(Set(visits.map(\.operation)).count == 1)
    }

    @Test(arguments: [false, true])
    func `forwarding holds an unanswered redirect and respects task cancellation`(cancel: Bool) async throws {
        D03RedirectProbe.reset()
        let server = try D03HTTPServer()
        let consumer = D03RedirectConsumer(mode: "pending")
        let session = d03Session(delegate: consumer, intercepted: true)
        D03RedirectProbe.routes.withLock { $0 = [D03Route(session: session, name: "waiting", scenario: "forward")] }
        defer {
            consumer.observation.withLock { $0.pending = nil }
            session.invalidateAndCancel()
            D03RedirectProbe.reset()
        }
        let task = session.dataTask(with: server.url())
        task.resume()
        try #require(await d02Eventually {
            server.poll { _ in D03HTTPReply(status: 302, location: "/final") }
            return consumer.observation.withLock { $0.pending != nil }
        })
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
        #expect(consumer.observation.withLock { $0.error?.code } == (cancel ? URLError.cancelled.rawValue : nil))
        #expect(server.requests.count == (cancel ? 1 : 2))
    }
}

private func installForwardingDecisionObservation(_ consumer: D03RedirectConsumer) {
    consumer.decisionObserver.withLock { observer in
        observer = { task, choice in
            if choice == nil {
                let operation = D03RedirectProbe.operations.withLock { $0[ObjectIdentifier(task)] }
                operation?.forwarding.withLock { $0 }?.refuse()
            }
        }
    }
    consumer.decisionPreparation.withLock { prepare in
        prepare = { task, choice in
            guard let choice else { return }
            let operation = D03RedirectProbe.operations.withLock { $0[ObjectIdentifier(task)] }
            // Capture the consumer's effective in-memory body before
            // Foundation converts it to a stream on the next protocol.
            if choice.httpBodyStream == nil {
                operation?.body.withLock { $0 = choice.httpBody }
            }
        }
    }
}
