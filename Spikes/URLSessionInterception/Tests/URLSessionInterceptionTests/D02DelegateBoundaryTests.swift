import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization
import Testing

#if canImport(Darwin)
    private typealias DelayedDecision = @Sendable (URLSession.DelayedRequestDisposition, URLRequest?) -> Void
    private typealias ChallengeDecision = @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

    private final class EmptyDataDelegate: NSObject, URLSessionDataDelegate {}

    private final class UnsupportedDecisionDelegate: NSObject, URLSessionDataDelegate {
        func urlSession(_: URLSession, task _: URLSessionTask,
                        needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void)
        {
            completionHandler(nil)
        }

        func urlSession(_: URLSession, dataTask _: URLSessionDataTask, willCacheResponse _: CachedURLResponse,
                        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void)
        {
            completionHandler(nil)
        }

        func urlSession(_: URLSession, task _: URLSessionTask, willBeginDelayedRequest _: URLRequest,
                        completionHandler: @escaping DelayedDecision)
        {
            completionHandler(.continueLoading, nil)
        }

        func urlSession(_: URLSession, didReceive _: URLAuthenticationChallenge,
                        completionHandler: @escaping ChallengeDecision)
        {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private final class BoundaryProxy: NSObject, URLSessionDataDelegate {
        let consumer: D02ControlledConsumer
        init(consumer: D02ControlledConsumer) {
            self.consumer = consumer
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
        {
            consumer.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            consumer.urlSession(session, dataTask: dataTask, didReceive: data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            consumer.urlSession(session, task: task, didCompleteWithError: error)
        }
    }

    private final class CreationProxyDelegate: NSObject, URLSessionTaskDelegate {
        let fallback: D02ControlledConsumer
        let observed = Mutex<[Bool]>([])
        init(fallback: D02ControlledConsumer) {
            self.fallback = fallback
        }

        func urlSession(_: URLSession, didCreateTask task: URLSessionTask) {
            let supplied = task.delegate as? D02ControlledConsumer
            observed.withLock { $0.append(supplied != nil) }
            task.delegate = BoundaryProxy(consumer: supplied ?? fallback)
        }
    }

    private final class DelegateGuardProtocol: URLProtocol {
        static let observations = Mutex<[Bool]>([])
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
            let protected = task?.delegate is BoundaryProxy
            Self.observations.withLock { $0.append(protected) }
            guard protected else {
                client?.urlProtocol(self, didFailWithError: NSError(domain: "D02UnproxiedDelegate", code: 1))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 203,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("guarded".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Suite(.serialized)
    struct D02DelegateBoundaryTests {
        @Test
        func `optional unsupported decision methods can be detected before setup`() {
            let empty = EmptyDataDelegate()
            let unsupported = UnsupportedDecisionDelegate()
            let selectors = [
                #selector(URLSessionTaskDelegate.urlSession(_:task:needNewBodyStream:)),
                #selector(URLSessionDataDelegate.urlSession(_:dataTask:willCacheResponse:completionHandler:)),
                #selector(URLSessionTaskDelegate.urlSession(_:task:willBeginDelayedRequest:completionHandler:)),
                #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:)),
            ]
            for selector in selectors {
                #expect(!empty.responds(to: selector))
                #expect(unsupported.responds(to: selector))
            }
        }

        @Test(arguments: ["delegate", "async", "asyncDelegate", "lateOverride"])
        func `creation hook can wrap delegates and loading can detect replacement`(presentation: String) async throws {
            DelegateGuardProtocol.observations.withLock { $0 = [] }
            let listener = try D02LoopbackListener()
            let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/delegation"))
            let consumer = D02ControlledConsumer()
            let manager = CreationProxyDelegate(fallback: consumer)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.protocolClasses = [DelegateGuardProtocol.self]
            let session = URLSession(configuration: configuration, delegate: manager, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            if presentation.hasPrefix("async") {
                do {
                    let supplied = presentation == "asyncDelegate" ? consumer : nil
                    let (body, _) = try await session.data(from: url, delegate: supplied)
                    consumer.complete(data: body, error: nil)
                } catch {
                    consumer.complete(data: nil, error: error)
                }
            } else {
                let task = session.dataTask(with: url)
                if presentation == "lateOverride" {
                    task.delegate = consumer
                }
                task.resume()
            }
            try #require(await d02Eventually { consumer.result.withLock { $0.completed } })
            listener.poll()
            let result = consumer.result.withLock { $0 }
            print("D02 delegate boundary \(presentation): creationSupplied=\(manager.observed.withLock { $0 }), " +
                "protected=\(DelegateGuardProtocol.observations.withLock { $0 }), " +
                "error=\(result.errorDomain ?? "nil"), connections=\(listener.connections)")
            #expect(manager.observed.withLock { $0.count } == 1)
            #expect(DelegateGuardProtocol.observations.withLock { $0 } == [presentation != "lateOverride"])
            #expect(listener.connections == 0)
            if presentation == "lateOverride" {
                #expect(result.errorDomain == "D02UnproxiedDelegate")
                #expect(result.body.isEmpty)
            } else {
                #expect(result.errorDomain == nil)
                #expect(result.body == Data("guarded".utf8))
            }
        }
    }
#endif
