import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

// FN-11: stock Linux traps in the native URLProtocolClient redirect callback.
// Restore all assertions on a repaired runtime, or opt in to the crash probe.
var d03CanPresentCustomRedirects: Bool {
    #if os(Linux)
        ProcessInfo.processInfo.environment["DIORAMA_VERIFY_FOUNDATION_FIXES"] == "1" ||
            ProcessInfo.processInfo.environment["DIORAMA_D03_UNSAFE_REDIRECT"] == "1"
    #else
        true
    #endif
}

@Suite(.serialized, .enabled(if: d03CanPresentCustomRedirects,
                             "FN-11: native custom redirect notification traps on unpatched Linux"))
struct D03RedirectTests {
    @Test(arguments: ["automatic", "follow", "modify", "refuse"])
    func `custom redirect decisions retain task ownership`(mode: String) async throws {
        D03RedirectProbe.reset()
        let listener = try D02LoopbackListener()
        let consumer = D03RedirectConsumer(mode: mode)
        let session = d03Session(delegate: mode == "automatic" ? nil : consumer, intercepted: true)
        D03RedirectProbe.routes.withLock { $0 = [D03Route(session: session, name: "owner")] }
        defer {
            session.invalidateAndCancel()
            D03RedirectProbe.reset()
        }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/start"))
        consumer.decisionObserver.withLock { observer in
            observer = { task, request in
                guard request == nil,
                      let delivery = D03RedirectProbe.deliveries.withLock({ $0[ObjectIdentifier(task)] })
                else { return }
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
                delivery.head(response: response)
                delivery.bytes("refused")
                delivery.finish()
            }
        }
        let task = session.dataTask(with: url) { data, response, error in
            consumer.complete(data: data, response: response, error: error)
        }
        task.resume()
        try #require(await d02Eventually { consumer.observation.withLock { $0.completions > 0 } })
        let result = consumer.observation.withLock { $0 }
        let visits = D03RedirectProbe.visits.withLock { $0 }
        print("D03 custom redirect \(mode): visits=\(visits.map { $0.request.url!.path }), " +
            "tasks=\(visits.map(\.task)), owners=\(visits.map(\.owner)), " +
            "decisions=\(result.proposals.count), error=\(String(describing: result.error))")
        #expect(result.error == nil)
        #expect(result.body == Data((mode == "refuse" ? "refused" : "final").utf8))
        #expect(result.proposals.count == (mode == "automatic" ? 0 : 1))
        #expect(visits.count == (mode == "refuse" ? 1 : 2))
        #expect(Set(visits.map(\.instance)).count == visits.count)
        #expect(Set(visits.map(\.operation)).count == 1)
        #expect(visits.allSatisfy { $0.task == ObjectIdentifier(task) && $0.owner == "owner" })
        listener.poll()
        #expect(listener.connections == 0)
    }

    @Test(arguments: ["multiple", "loop"])
    func `custom redirect chains retain one operation and native limits`(scenario: String) async throws {
        D03RedirectProbe.reset()
        let listener = try D02LoopbackListener()
        let consumer = D03RedirectConsumer()
        let session = d03Session(delegate: consumer, intercepted: true)
        D03RedirectProbe.routes.withLock {
            $0 = [D03Route(session: session, name: "chain", scenario: scenario)]
        }
        defer {
            session.invalidateAndCancel()
            D03RedirectProbe.reset()
        }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/start"))
        let task = session.dataTask(with: url)
        task.resume()
        try #require(await d02Eventually { consumer.observation.withLock { $0.completions > 0 } })
        let result = consumer.observation.withLock { $0 }
        let visits = D03RedirectProbe.visits.withLock { $0 }
        print("D03 custom \(scenario): visits=\(visits.count), decisions=\(result.proposals.count), " +
            "error=\(String(describing: result.error))")
        #expect(Set(visits.map(\.operation)).count == 1)
        #expect(Set(visits.map(\.instance)).count == visits.count)
        #expect(visits.allSatisfy { $0.task == ObjectIdentifier(task) && $0.owner == "chain" })
        if scenario == "loop" {
            #expect(result.error?.domain == NSURLErrorDomain)
            #expect(result.error?.code == URLError.httpTooManyRedirects.rawValue)
            #expect(visits.count == 21)
        } else {
            #expect(result.error == nil)
            #expect(result.body == Data("final".utf8))
            #expect(visits.map { $0.request.url?.path } == ["/start", "/hop", "/final"])
            #expect(result.statuses == [302, 302])
        }
        listener.poll()
        #expect(listener.connections == 0)
    }

    @Test(arguments: ["follow", "cancel", "mismatch"])
    func `pending custom redirect gates continuation and anchors its delay`(decision: String) async throws {
        D03RedirectProbe.reset()
        let listener = try D02LoopbackListener()
        let consumer = D03RedirectConsumer(mode: "pending")
        let session = d03Session(delegate: consumer, intercepted: true)
        D03RedirectProbe.routes.withLock {
            $0 = [D03Route(session: session, name: "pending", delay: .milliseconds(150))]
        }
        defer {
            consumer.observation.withLock { $0.pending = nil }
            session.invalidateAndCancel()
            D03RedirectProbe.reset()
        }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/start"))
        let task = session.dataTask(with: url)
        task.resume()
        try #require(await d02Eventually { consumer.observation.withLock { $0.pending != nil } })
        try await Task.sleep(for: .milliseconds(250))
        #expect(D03RedirectProbe.visits.withLock { $0.count } == 1)
        #expect(consumer.observation.withLock { $0.completions == 0 && $0.body.isEmpty })
        let decided = ContinuousClock.now
        switch decision {
        case "cancel": task.cancel()
        case "mismatch": consumer.decide(URLRequest(url: url.appendingPathComponent("unrecorded")))
        default: consumer.decide(consumer.observation.withLock { $0.proposals.last })
        }
        try #require(await d02Eventually { consumer.observation.withLock { $0.completions > 0 } })
        let result = consumer.observation.withLock { $0 }
        #expect(result.completions == 1)
        switch decision {
        case "cancel":
            #expect(result.error?.domain == NSURLErrorDomain)
            #expect(result.error?.code == URLError.cancelled.rawValue)
            #expect(D03RedirectProbe.visits.withLock { $0.count } == 1)
        case "mismatch":
            #expect(result.error?.domain == "D03IncompatibleContinuation")
            #expect(result.body.isEmpty)
        default:
            #expect(result.error == nil)
            #expect(result.body == Data("final".utf8))
            let operation = try #require(D03RedirectProbe.operations.withLock { $0[ObjectIdentifier(task)] })
            let delivery = try #require(operation.deliveryTimes.withLock { $0.first })
            #expect(decided.duration(to: delivery) >= .milliseconds(120))
        }
        listener.poll()
        #expect(listener.connections == 0)
    }

    @Test
    func `identical concurrent redirect chains stay with their owning sessions`() async throws {
        D03RedirectProbe.reset()
        let listener = try D02LoopbackListener()
        let first = d03Session(intercepted: true)
        let second = d03Session(intercepted: true)
        D03RedirectProbe.routes.withLock {
            $0 = [
                D03Route(session: first, name: "first", scenario: "multiple"),
                D03Route(session: second, name: "second", scenario: "multiple"),
            ]
        }
        defer {
            first.invalidateAndCancel()
            second.invalidateAndCancel()
            D03RedirectProbe.reset()
        }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/start"))
        async let firstResult = first.data(from: url)
        async let secondResult = second.data(from: url)
        #expect(try await firstResult.0 == Data("final".utf8))
        #expect(try await secondResult.0 == Data("final".utf8))
        let visits = D03RedirectProbe.visits.withLock { $0 }
        #expect(visits.count == 6)
        #expect(Set(visits.map(\.task)).count == 2)
        #expect(Set(visits.map(\.operation)).count == 2)
        for name in ["first", "second"] {
            let owned = visits.filter { $0.owner == name }
            #expect(owned.count == 3)
            #expect(Set(owned.map(\.task)).count == 1)
            #expect(Set(owned.map(\.operation)).count == 1)
        }
        listener.poll()
        #expect(listener.connections == 0)
    }

    @Test(arguments: ["delegate", "completion", "async", "asyncDelegate", "taskDelegate"])
    func `redirects reach each supported consumer presentation`(presentation: String) async throws {
        D03RedirectProbe.reset()
        let listener = try D02LoopbackListener()
        let consumer = D03RedirectConsumer()
        let supplied = D03RedirectConsumer()
        let session = d03Session(delegate: consumer, intercepted: true)
        D03RedirectProbe.routes.withLock { $0 = [D03Route(session: session, name: presentation)] }
        defer {
            session.invalidateAndCancel()
            D03RedirectProbe.reset()
        }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/start"))
        switch presentation {
        case "delegate": session.dataTask(with: url).resume()
        case "completion":
            session.dataTask(with: url) { data, response, error in
                consumer.complete(data: data, response: response, error: error)
            }.resume()
        case "taskDelegate":
            let task = session.dataTask(with: url)
            task.delegate = supplied
            task.resume()
        default:
            let (data, response) = try await session.data(for: URLRequest(url: url),
                                                          delegate: presentation == "asyncDelegate" ? supplied : nil)
            consumer.complete(data: data, response: response, error: nil)
        }
        let resultOwner = presentation == "taskDelegate" ? supplied : consumer
        try #require(await d02Eventually { resultOwner.observation.withLock { $0.completions > 0 } })
        let result = resultOwner.observation.withLock { $0 }
        let redirectOwner = ["taskDelegate", "asyncDelegate"].contains(presentation) ? supplied : consumer
        #expect(redirectOwner.observation.withLock { $0.proposals.count } == 1)
        if redirectOwner === supplied {
            #expect(consumer.observation.withLock { $0.proposals.isEmpty })
        }
        #expect(result.error == nil)
        #expect(result.body == Data("final".utf8))
        let visits = D03RedirectProbe.visits.withLock { $0 }
        #expect(visits.count == 2)
        #expect(Set(visits.map(\.operation)).count == 1)
        #expect(visits.allSatisfy { $0.owner == presentation })
        listener.poll()
        #expect(listener.connections == 0)
    }
}
