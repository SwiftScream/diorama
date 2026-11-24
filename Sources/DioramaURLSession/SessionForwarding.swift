import DioramaCore
import DioramaHTTP
import Foundation
import Synchronization

/// A private task has one aggregate consumer. It may outlive record finalization.
/// Its weak recorder drops all execution ownership at detachment. Its delegate
/// queue serializes native head, content, decisions, and completion.
final class SessionForwarding: NSObject, URLSessionDataDelegate {
    private struct Observation: Sendable {
        weak var recorder: SessionRecorder?
        let handle: HTTPCaptureOperation
    }

    private let observation: Mutex<Observation?>
    private let received = Mutex<SessionResponse?>(nil)
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
        let task = session.dataTask(with: request)
        delivery.onCancel { executor.async { task.cancel() } }
        delivery.whileOpen { task.resume() }
        session.finishTasksAndInvalidate()
    }

    func urlSession(
        _: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        var recorder: SessionRecorder?
        delivery.whileOpen { recorder = observation.withLock { $0?.recorder } }
        let time = recorder?.responseTime()
        received.withLock { $0 = SessionResponse(native: response, time: time) }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        received.withLock { response in
            if response?.body == nil {
                response?.body = data
            } else {
                response?.body?.append(data)
            }
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: any Error?) {
        // stopLoading ends observation before canceling the private task.
        // Claim the native result under the same gate, before conversion.
        var item: Observation?
        delivery.whileOpen { item = takeObservation() }
        let response = received.withLock { value in
            defer { value = nil }
            return value
        }
        if let error {
            if let item {
                _ = item.recorder?.complete(.failed(error, partial: response), handle: item.handle)
            }
            if let response {
                delivery.response(response.native)
                if let body = response.body {
                    delivery.bytes(body)
                }
            }
            delivery.finish(error)
            return
        }
        guard var response else {
            if let item {
                item.recorder?.reject(item.handle, reason: "urlsession.missing-native-response")
            }
            delivery.finish(SessionBridgeError.conversion)
            return
        }
        let body = response.body ?? Data()
        response.body = body
        let prepared = item.flatMap { $0.recorder?.complete(.returned(response), handle: $0.handle) }
        delivery.response(prepared ?? response.native)
        delivery.bytes(body)
        delivery.finish()
    }

    private func takeObservation() -> Observation? {
        observation.withLock { value in
            defer { value = nil }
            return value
        }
    }

    private func rejectObservation(_ reason: StaticString) {
        if let item = takeObservation() {
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
