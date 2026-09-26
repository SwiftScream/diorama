import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization
import Testing

@Suite(.serialized)
struct D05ReplayTests {
    @Test(arguments: ["delegate", "completion", "async", "asyncDelegate"], ["beforeHead", "partialBody"])
    func `open replay is canceled and native presentation drains`(presentation: String, phase: String) async throws {
        let listener = try D02LoopbackListener()
        let observer = D05NativeObserver()
        let session = d05ReplaySession(observer)
        defer { session.invalidateAndCancel(); D05ReplayProtocol.operations.withLock { $0 = [:] } }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/replay"))
        let producer = start(presentation, session: session, observer: observer, url: url)
        defer { producer.cancel() }
        try #require(await d02Eventually { D05ReplayProtocol.operations.withLock { $0.count == 1 } })
        let operation = try #require(D05ReplayProtocol.operations.withLock { $0.values.first })
        if phase == "partialBody" {
            operation.delivery.head()
            operation.delivery.bytes("first-")
            if presentation == "delegate" {
                try #require(await d02Eventually { observer.events.withLock { !$0.body.isEmpty } })
            }
        }
        try #require(await d05CloseReplay(session, observer: observer))
        await producer.value
        #expect(operation.task.state == .completed)
        #expect(observer.events.withLock { $0.completions } == 1)
        #expect(observer.events.withLock { $0.errorCode } == URLError.cancelled.rawValue)
        let count = observer.events.withLock { $0.sequence.count }
        #expect(!operation.delivery.bytes("late"))
        operation.delivery.head()
        operation.delivery.finish()
        await d05QueueBarrier(session.delegateQueue)
        #expect(observer.events.withLock { $0.sequence.count } == count)
        #expect(D05ReplayProtocol.operations.withLock { $0.isEmpty })
        listener.poll()
        #expect(listener.connections == 0)
    }

    @Test(arguments: ["body", "completion"], [1, 4])
    func `quiescence waits for an executing consumer callback`(boundary: String, width: Int) async throws {
        let block = D05CallbackBlock()
        let observer = D05NativeObserver(block: block, blockAt: boundary)
        let session = d05ReplaySession(observer, width: width)
        defer { block.release(); session.invalidateAndCancel(); D05ReplayProtocol.operations.withLock { $0 = [:] } }
        let task = try boundary == "body" ? session.dataTask(with: #require(URL(string: "http://d05.invalid/replay"))) :
            session.dataTask(with: #require(URL(string: "http://d05.invalid/replay"))) { data, _, error in
                observer.complete(data: data, error: error)
            }
        task.resume()
        try #require(await d02Eventually { D05ReplayProtocol.operations.withLock { !$0.isEmpty } })
        let operation = try #require(D05ReplayProtocol.operations.withLock { $0.values.first })
        operation.delivery.head()
        operation.delivery.bytes("first-")
        if boundary == "completion" {
            operation.delivery.finish()
        }
        try #require(await d02Eventually { block.entered.withLock { $0 } })
        let began = Mutex(false)
        let returned = Mutex(false)
        let closer = Task {
            began.withLock { $0 = true }
            let result = await d05CloseReplay(session, observer: observer)
            observer.event("quiescent")
            returned.withLock { $0 = true }
            return result
        }
        try #require(await d02Eventually { began.withLock { $0 } })
        #expect(!returned.withLock { $0 })
        block.release()
        #expect(await closer.value)
        #expect(task.state == .completed)
        #expect(observer.events.withLock { $0.completions } == 1)
        let expectedError = boundary == "body" ? URLError.cancelled.rawValue : nil
        #expect(observer.events.withLock { $0.errorCode } == expectedError)
        #expect(observer.events.withLock { $0.body } == Data("first-".utf8))
        #expect(!operation.delivery.bytes("late"))
        let events = observer.events.withLock { $0.sequence }
        let callbackReturn = try #require(events.firstIndex(of: "\(boundary)Returned"))
        let quiescent = try #require(events.firstIndex(of: "quiescent"))
        #expect(callbackReturn < quiescent)
    }

    @Test(arguments: d05DecisionPhases)
    func `unanswered replay decision is released without a late continuation`(phase: String) async throws {
        let listener = try D02LoopbackListener()
        let observer = D05NativeObserver(holdDecision: true)
        let session = d05ReplaySession(observer)
        defer { session.invalidateAndCancel(); D05ReplayProtocol.operations.withLock { $0 = [:] } }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/replay"))
        let task = session.dataTask(with: url)
        task.resume()
        try #require(await d02Eventually { D05ReplayProtocol.operations.withLock { !$0.isEmpty } })
        let operation = try #require(D05ReplayProtocol.operations.withLock { $0.values.first })
        present(phase, operation: operation, url: url)
        try #require(await d02Eventually { observer.events.withLock { $0.pending != nil } })
        #expect(observer.events.withLock { $0.completions } == 0)
        try #require(await d05CloseReplay(session, observer: observer))
        let events = observer.events.withLock { $0.sequence }
        observer.answerPending()
        #expect(!operation.delivery.bytes("late"))
        await d05QueueBarrier(session.delegateQueue)
        #expect(observer.events.withLock { $0.sequence } == events)
        #expect(observer.events.withLock { $0.completions } == 1)
        #expect(task.state == .completed)
        listener.poll()
        #expect(listener.connections == 0)
    }

    private func present(_ phase: String, operation: D05ReplayOperation, url: URL) {
        switch phase {
        case "response": operation.delivery.head()
        case "redirect":
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": "/next"])!
            operation.delivery.redirect(to: URLRequest(url: url.appendingPathComponent("next")), response: response)
        default:
            let space = URLProtectionSpace(host: "127.0.0.1", port: url.port!, protocol: "http", realm: "d05",
                                           authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
            let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
            let sender = D04Sender { _ in operation.delivery.bytes("unexpected-answer") }
            operation.delivery.challenge(URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                                                                    previousFailureCount: 0, failureResponse: response,
                                                                    error: nil, sender: sender))
        }
    }

    private func start(_ presentation: String, session: URLSession, observer: D05NativeObserver,
                       url: URL) -> Task<Void, Never>
    {
        Task {
            if presentation == "delegate" {
                session.dataTask(with: url).resume()
            } else if presentation == "completion" {
                session.dataTask(with: url) { data, _, error in observer.complete(data: data, error: error) }.resume()
            } else {
                do {
                    let delegate = presentation == "asyncDelegate" ? observer : nil
                    let (data, _) = try await session.data(from: url, delegate: delegate)
                    observer.complete(data: data, error: nil)
                } catch { observer.complete(data: nil, error: error) }
            }
        }
    }
}

private let d05DecisionPhases: [String] = {
    #if canImport(FoundationNetworking)
        // FN-11 traps and FN-15 can start live HTTP. Restore only on a patched
        // runtime; the ordinary Linux response-decision cancellation still runs.
        return ProcessInfo.processInfo.environment["DIORAMA_VERIFY_FOUNDATION_FIXES"] == "1" ?
            ["response", "redirect", "challenge"] : ["response"]
    #else
        return ["response", "redirect", "challenge"]
    #endif
}()
