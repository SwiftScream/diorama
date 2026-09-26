import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization

final class D04ForwardHop: NSObject, URLSessionDataDelegate {
    private let queue = DispatchQueue(label: "D04ForwardHop")
    private let session = Mutex<URLSession?>(nil)
    private let delivery: D02ControlledDelivery

    init(delivery: D02ControlledDelivery) {
        self.delivery = delivery
    }

    func start(_ request: URLRequest) {
        queue.async {
            let configuration = D04SyntheticProbe.forwardingConfiguration.withLock {
                $0?.copy() as? URLSessionConfiguration
            } ?? .ephemeral
            configuration.urlCache = nil
            let native = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session.withLock { $0 = native }
            native.dataTask(with: request).resume()
        }
    }

    func stop() {
        delivery.stop()
        queue.async {
            let native = self.session.withLock { value in
                defer { value = nil }
                return value
            }
            native?.invalidateAndCancel()
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping D04Answer)
    {
        let method = challenge.protectionSpace.authenticationMethod
        #if canImport(Darwin)
            if method == NSURLAuthenticationMethodServerTrust {
                // Default TLS validation is live transport behavior. Do not
                // expose security objects as a recordable outer challenge.
                completionHandler(.performDefaultHandling, nil)
                return
            }
        #endif
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
              challenge.failureResponse is HTTPURLResponse
        else {
            delivery.finish(error: NSError(domain: "D04UnsupportedAuthenticationChallenge", code: 1))
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let sender = D04Sender(nativeAnswer: completionHandler) { decision in
            D04SyntheticProbe.decisions.withLock { $0.append(decision) }
        }
        D04SyntheticProbe.sender.withLock { $0 = sender }
        delivery.challenge(URLAuthenticationChallenge(authenticationChallenge: challenge, sender: sender))
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
        delivery.finish(error: error as NSError?)
        session.finishTasksAndInvalidate()
    }
}

func d04ForwardingSession(_ consumer: D04Consumer,
                          configuration supplied: URLSessionConfiguration? = nil) -> URLSession
{
    let configuration = supplied?.copy() as? URLSessionConfiguration ?? .ephemeral
    configuration.urlCache = nil
    D04SyntheticProbe.forwardingConfiguration.withLock { $0 = configuration.copy() as? URLSessionConfiguration }
    configuration.protocolClasses = [D04ForwardingProtocol.self]
    return URLSession(configuration: configuration, delegate: D04DelegateProxy(consumer), delegateQueue: nil)
}

final class D04ForwardingProtocol: URLProtocol {
    private let hop = Mutex<D04ForwardHop?>(nil)
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
        let forward = D04ForwardHop(delivery: D02ControlledDelivery(self))
        hop.withLock { $0 = forward }
        forward.start(request)
    }

    override func stopLoading() {
        hop.withLock { $0 }?.stop()
    }
}
