import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization
import Testing

private struct PreparedBody: Sendable {
    let data: Data?
    let hasStream: Bool
}

private struct BodyForwardingState: Sendable {
    let session: URLSession
    let delivery: D02ControlledDelivery
    let observer: BodyForwardingDelegate
}

private final class BodyForwardingWorker: Sendable {
    private let queue = DispatchQueue(label: "D02BodyForwarding")
    private let state = Mutex<(stopped: Bool, active: BodyForwardingState?)>((false, nil))

    func start(request: URLRequest, delivery: D02ControlledDelivery) {
        let operation: @Sendable () -> Void = {
            guard !self.state.withLock({ $0.stopped }) else {
                delivery.stop()
                return
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            // The adapter's protocol is not installed in its private session.
            let observer = BodyForwardingDelegate(delivery: delivery)
            let session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
            self.state.withLock {
                $0.active = BodyForwardingState(session: session, delivery: delivery, observer: observer)
            }
            session.dataTask(with: request).resume()
        }
        // Opt-in reproducer: FoundationNetworking traps on synchronous session
        // reentry from startLoading. Ordinary tests use the isolated queue.
        if ProcessInfo.processInfo.environment["DIORAMA_D02_INLINE_FORWARDING"] == "1" {
            operation()
        } else {
            queue.async(execute: operation)
        }
    }

    func stop() {
        queue.async {
            let previous = self.state.withLock { state in
                defer {
                    state.stopped = true
                    state.active = nil
                }
                return state.active
            }
            previous?.delivery.stop()
            if previous?.observer.completed.withLock({ $0 }) == true {
                previous?.session.finishTasksAndInvalidate()
            } else {
                previous?.session.invalidateAndCancel()
            }
        }
    }
}

/// This fixture exercises only the initial request. Redirect correlation and
/// native callback quiescence remain separate D03/D05 experiments.
private final class BodyForwardingProtocol: URLProtocol {
    static let prepared = Mutex<[PreparedBody]>([])
    private let worker = BodyForwardingWorker()

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canInit(with _: URLSessionTask) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let original = task?.originalRequest else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "D02MissingOriginal", code: 1))
            return
        }
        guard original.httpBodyStream == nil else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "D02BodyStreamUnsupported", code: 1))
            return
        }
        // Apple can expose an in-memory body as a stream on the protocol's
        // request. Preserve its original stable form before private forwarding.
        var forwarded = request
        forwarded.httpBodyStream = nil
        forwarded.httpBody = original.httpBody
        forwarded.cachePolicy = .reloadIgnoringLocalCacheData
        Self.prepared.withLock {
            $0.append(PreparedBody(data: forwarded.httpBody, hasStream: forwarded.httpBodyStream != nil))
        }
        worker.start(request: forwarded, delivery: D02ControlledDelivery(self))
    }

    override func stopLoading() {
        worker.stop()
    }
}

private final class BodyForwardingDelegate: NSObject, URLSessionDataDelegate {
    let delivery: D02ControlledDelivery
    let completed = Mutex(false)
    init(delivery: D02ControlledDelivery) {
        self.delivery = delivery
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        delivery.head(response: response)
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        delivery.bytes(data)
    }

    func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // Native completion can be in flight when the outer task finishes.
        // Record this before delivery so normal teardown does not recancel it.
        completed.withLock { $0 = true }
        delivery.finish(error: error as NSError?)
        session.finishTasksAndInvalidate()
    }
}

private let bodyPresentations = ["delegate", "completion", "async", "asyncDelegate"]

private func startBodyRequest(_ presentation: String, request: URLRequest, session: URLSession,
                              consumer: D02ControlledConsumer) async
{
    switch presentation {
    case "delegate": session.dataTask(with: request).resume()
    case "completion":
        session.dataTask(with: request) { data, _, error in consumer.complete(data: data, error: error) }.resume()
    default:
        do {
            // Async return bytes and delegate observations are separate views;
            // a delegate callback may still be queued when the await returns.
            let supplied = presentation == "asyncDelegate" ? D02ControlledConsumer() : nil
            let (data, _) = try await session.data(for: request, delegate: supplied)
            consumer.complete(data: data, error: nil)
        } catch {
            consumer.complete(data: nil, error: error)
        }
    }
}

@Suite(.serialized)
struct D02BodyForwardingTests {
    @Test(arguments: bodyPresentations, ["absent", "empty", "bytes"])
    func `initial body forwarding matches native HTTP bytes`(presentation: String, bodyKind: String) async throws {
        let body: Data? = switch bodyKind {
        case "empty": Data()
        case "bytes": Data([0, 1, 127, 255])
        default: nil
        }
        for intercepted in [false, true] {
            BodyForwardingProtocol.prepared.withLock { $0 = [] }
            let server = try NativeHTTPServer()
            let url = try #require(URL(string: "http://127.0.0.1:\(server.listener.port)/body"))
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("preserved", forHTTPHeaderField: "X-D02-Probe")
            let consumer = D02ControlledConsumer()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            if intercepted {
                configuration.protocolClasses = [BodyForwardingProtocol.self]
            }
            let session = URLSession(configuration: configuration, delegate: consumer, delegateQueue: nil)
            let operation = Task {
                await startBodyRequest(presentation, request: request, session: session, consumer: consumer)
            }
            defer {
                session.invalidateAndCancel()
                operation.cancel()
            }
            try #require(await d02Eventually {
                server.receiveRequest() && server.requestBody?.count == (body?.count ?? 0)
            })
            checkWireRequest(server, body: body)
            try #require(server.send(NativeHTTPServer.responseStart + "second"))
            try #require(await d02Eventually { consumer.result.withLock { $0.completed } })
            await operation.value
            #expect(consumer.result.withLock { $0.errorDomain } == nil)
            #expect(consumer.result.withLock { $0.body } == Data("first-second".utf8))
            let prepared = BodyForwardingProtocol.prepared.withLock { $0 }
            #expect(prepared.count == (intercepted ? 1 : 0))
            if intercepted {
                #expect(prepared.first?.data == body)
                #expect(prepared.first?.hasStream == false)
            }
            server.listener.poll()
            #expect(server.acceptedConnections == 1)
            #expect(server.listener.connections == 0)
            print("D02 forwarded body \(presentation)/\(bodyKind)/intercepted=\(intercepted): " +
                "wireBytes=\(server.requestBody?.count ?? -1), prepared=\(prepared.count)")
        }
    }

    @Test(arguments: bodyPresentations)
    func `initial body streams reject before private forwarding`(presentation: String) async throws {
        BodyForwardingProtocol.prepared.withLock { $0 = [] }
        let listener = try D02LoopbackListener()
        var request = try URLRequest(url: #require(URL(string: "http://127.0.0.1:\(listener.port)/stream")))
        request.httpMethod = "POST"
        request.httpBodyStream = InputStream(data: Data([0, 1, 127, 255]))
        let consumer = D02ControlledConsumer()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BodyForwardingProtocol.self]
        let session = URLSession(configuration: configuration, delegate: consumer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        await startBodyRequest(presentation, request: request, session: session, consumer: consumer)
        try #require(await d02Eventually { consumer.result.withLock { $0.completed } })
        listener.poll()
        #expect(consumer.result.withLock { $0.errorDomain } == "D02BodyStreamUnsupported")
        #expect(consumer.result.withLock { $0.body.isEmpty })
        #expect(BodyForwardingProtocol.prepared.withLock { $0.isEmpty })
        #expect(listener.connections == 0)
    }
}

private func checkWireRequest(_ server: NativeHTTPServer, body: Data?) {
    #expect(server.requestLine == "POST /body HTTP/1.1")
    #expect(server.requestBody == (body ?? Data()))
    #expect(server.requestHeader("Content-Length") == String(body?.count ?? 0))
    #expect(server.requestHeader("Content-Type") == "application/octet-stream")
    #expect(server.requestHeader("X-D02-Probe") == "preserved")
}
