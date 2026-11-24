import DioramaHTTP
import Foundation
import Synchronization

/// A private task has one aggregate consumer. It may outlive record finalization.
/// Its weak recorder drops all execution ownership at detachment. Its delegate
/// queue serializes native head, content, decisions, and completion.
final class SessionForwarding: NSObject, URLSessionTaskDelegate {
    private struct Observation: Sendable {
        weak var recorder: SessionRecorder?
        let handle: HTTPCaptureOperation
    }

    private let observation: Mutex<Observation?>
    private let delivery: SessionDelivery

    init(recorder: SessionRecorder, handle: HTTPCaptureOperation?, delivery: SessionDelivery) {
        observation = Mutex(handle.map { Observation(recorder: recorder, handle: $0) })
        self.delivery = delivery
    }

    func start(_ request: URLRequest, configuration: URLSessionConfiguration, executor: DispatchQueue) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.dataTask(with: request) { data, response, error in
            self.complete(data, response: response, error: error)
        }
        delivery.onCancel { executor.async { task.cancel() } }
        delivery.whileOpen { task.resume() }
        session.finishTasksAndInvalidate()
    }

    private func complete(_ data: Data?, response: URLResponse?, error: any Error?) {
        if let error {
            rejectObservation("urlsession.unsupported-native-failure")
            if let response {
                delivery.response(response)
            }
            if let data {
                delivery.bytes(data)
            }
            delivery.finish(error)
            return
        }
        guard let response else {
            rejectObservation("urlsession.missing-native-response")
            delivery.finish(SessionBridgeError.conversion)
            return
        }
        let item = observation.withLock { $0 }
        let prepared = item.flatMap { $0.recorder?.complete(response, data: data, handle: $0.handle) }
        delivery.response(prepared ?? response)
        if let data {
            delivery.bytes(data)
        }
        delivery.finish()
    }

    private func rejectObservation(_ reason: StaticString) {
        let item = observation.withLock { value in
            defer { value = nil }
            return value
        }
        if let item {
            item.recorder?.reject(item.handle, reason: reason)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        rejectObservation("urlsession.unsupported-redirect")
        completionHandler(request)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition,
                                                            URLCredential?) -> Void)
    {
        if challenge.protectionSpace.authenticationMethod != NSURLAuthenticationMethodServerTrust {
            rejectObservation("urlsession.unsupported-authentication")
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
