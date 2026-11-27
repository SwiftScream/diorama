import DioramaCore
import DioramaHTTP
import Foundation
import HTTPTypesFoundation
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

/// One incremental response per task. Live delivery can continue after the
/// recording observation detaches.
private final class ForwardedLoad: Sendable {
    private struct Observation: Sendable {
        weak var recorder: SessionRecorder?
        let handle: HTTPCaptureOperation
    }

    private let observation: Mutex<Observation?>
    private enum Progress { case awaitingHead, receivedHead, receivedSegment }

    private let progress = Mutex(Progress.awaitingHead)
    private let proxy: SessionRecordDelegate?
    private let delivery: SessionDelivery

    init(recorder: SessionRecorder, handle: HTTPCaptureOperation?, delivery: SessionDelivery) {
        observation = Mutex(handle.map { Observation(recorder: recorder, handle: $0) })
        proxy = delivery.task?.delegate as? SessionRecordDelegate
        if let handle {
            proxy?.bind(recorder, handle: handle)
        }
        self.delivery = delivery
    }

    func detachObservation() {
        observation.withLock { $0 = nil }
    }

    func receive(_ response: URLResponse) {
        delivery.whileOpen {
            progress.withLock { $0 = .receivedHead }
            var delivered = response
            if let item = observation.withLock({ $0 }), let recorder = item.recorder {
                let head: SessionRecorder.ResponseHead = proxy?.observesDisposition == true ? .preserve : .ordinary
                recorder.observe(item.handle, head: head) { context in
                    let value = try HTTPPreparation().response(reporter: recorder.execution.reporter, context: context)
                        .prepare(capturing: { try SessionMessage.response(response) }, purpose: .recording,
                                 reporter: recorder.execution.reporter, context: context)
                    guard let url = response.url, let native = HTTPURLResponse(httpResponse: value.value.head, url: url)
                    else { throw SessionBridgeError.conversion }
                    delivered = native
                    return .response(value.value)
                }
            }
            delivery.response(delivered)
        }
    }

    func receive(_ data: Data) {
        delivery.whileOpen {
            progress.withLock { $0 = .receivedSegment }
            if let item = observation.withLock({ $0 }) {
                observeTransport { item.recorder?.observe(item.handle) { _ in .segment(Array(data)) } }
            }
            delivery.bytes(data)
        }
    }

    func complete(_ error: any Error?) {
        delivery.whileOpen {
            let state = progress.withLock { $0 }
            if error == nil, state == .awaitingHead {
                rejectObservation("urlsession.missing-native-response")
                delivery.finish(SessionBridgeError.conversion)
                return
            }
            if let item = takeObservation(), let recorder = item.recorder {
                observeTransport {
                    if error == nil, state == .receivedHead {
                        recorder.observe(item.handle) { _ in .content(.bytes([])) }
                    }
                    recorder.complete(item.handle, error: error)
                }
            }
            delivery.finish(error)
        }
    }

    private func observeTransport(_ observation: () -> Void) {
        if let proxy {
            proxy.observeTransport(observation)
        } else {
            observation()
        }
    }

    private func takeObservation() -> Observation? {
        observation.withLock { value in
            defer { value = nil }
            return value
        }
    }

    func rejectObservation(_ reason: StaticString) {
        delivery.whileOpen {
            if let item = takeObservation() {
                item.recorder?.reject(item.handle, reason: reason)
            }
        }
    }
}
