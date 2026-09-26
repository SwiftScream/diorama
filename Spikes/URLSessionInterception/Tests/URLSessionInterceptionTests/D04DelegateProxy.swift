import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

typealias D04Answer = @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

/// Experimental decision bridge; the consumer answers the ordinary completion
/// handler. Native credentials stay transient inside that call. The D04 suite
/// serializes this single-operation fixture; it is not production routing.
final class D04DelegateProxy: NSObject, URLSessionDataDelegate {
    let consumer: D04Consumer

    init(_ consumer: D04Consumer) {
        self.consumer = consumer
    }

    func urlSession(_: URLSession, didCreateTask task: URLSessionTask) {
        if let consumer = task.delegate as? D04Consumer {
            task.delegate = D04DelegateProxy(consumer)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping D04Answer)
    {
        // Capture the exact pending continuation before native completion can
        // cause cancellation or another challenge. No sender lookup afterward.
        let sender = D04SyntheticProbe.sender.withLock { $0 }
        consumer.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
            completionHandler(disposition, credential)
            sender?.resolve(disposition, credential: credential)
        }
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
