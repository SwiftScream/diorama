import DioramaCore
import DioramaHTTP
import Foundation
import Synchronization

/// Task creation and invalidation run on the owner's serial forwarding queue.
/// The private delegate has its own serial queue for native callbacks.
struct SessionForwarding: Sendable {
    let session: URLSession
    private let delegate = ForwardingDelegate()

    init(configuration: URLSessionConfiguration) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    func start(_ request: URLRequest, recorder: SessionRecorder, handle: HTTPCaptureOperation?,
               delivery: SessionDelivery, executor: DispatchQueue)
    {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.dataTask(with: request)
        delegate.register(task, load: ForwardedLoad(recorder: recorder, handle: handle, delivery: delivery))
        delivery.onCancel { executor.async { task.cancel() } }
        task.resume()
    }

    func finish() {
        delegate.detachObservations()
        session.finishTasksAndInvalidate()
    }
}

private final class ForwardingDelegate: NSObject, URLSessionDataDelegate {
    private let loads = Mutex<[ObjectIdentifier: ForwardedLoad]>([:])

    func register(_ task: URLSessionTask, load: ForwardedLoad) {
        loads.withLock { $0[ObjectIdentifier(task)] = load }
    }

    func detachObservations() {
        loads.withLock { state in
            for load in state.values {
                load.detachObservation()
            }
        }
    }

    private func load(for task: URLSessionTask) -> ForwardedLoad? {
        loads.withLock { $0[ObjectIdentifier(task)] }
    }

    func urlSession(
        _: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        guard let load = load(for: dataTask) else { completionHandler(.cancel); return }
        load.receive(response)
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        load(for: dataTask)?.receive(data)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: any Error?) {
        let key = ObjectIdentifier(task)
        // Keep the route visible to shutdown until terminal delivery returns.
        defer { loads.withLock { _ = $0.removeValue(forKey: key) } }
        load(for: task)?.complete(error)
    }

    func urlSession(_: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        load(for: task)?.rejectObservation("urlsession.unsupported-redirect")
        completionHandler(request)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition,
                                                            URLCredential?) -> Void)
    {
        if challenge.protectionSpace.authenticationMethod != NSURLAuthenticationMethodServerTrust {
            load(for: task)?.rejectObservation("urlsession.unsupported-authentication")
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

/// One aggregate consumer per task. Live delivery can continue after the
/// recording observation detaches.
private final class ForwardedLoad: Sendable {
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

    func detachObservation() {
        observation.withLock { $0 = nil }
    }

    func receive(_ response: URLResponse) {
        var recorder: SessionRecorder?
        delivery.whileOpen { recorder = observation.withLock { $0?.recorder } }
        let time = recorder?.responseTime()
        received.withLock { $0 = SessionResponse(native: response, time: time) }
    }

    func receive(_ data: Data) {
        received.withLock { response in
            if response?.body == nil {
                response?.body = data
            } else {
                response?.body?.append(data)
            }
        }
    }

    func complete(_ error: any Error?) {
        // stopLoading ends observation before canceling the private task.
        // Claim the native result under the same gate, before conversion.
        let item = takeObservation()
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
        var item: Observation?
        delivery.whileOpen {
            item = observation.withLock { value in
                defer { value = nil }
                return value
            }
        }
        return item
    }

    func rejectObservation(_ reason: StaticString) {
        if let item = takeObservation() {
            item.recorder?.reject(item.handle, reason: reason)
        }
    }
}
