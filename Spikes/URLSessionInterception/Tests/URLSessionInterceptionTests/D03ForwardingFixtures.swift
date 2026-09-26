import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization

private struct D03ForwardState: Sendable {
    var session: URLSession?
    var task: URLSessionTask?
    var pending: (@Sendable (URLRequest?) -> Void)?
    var completed = false
    var stopped = false
}

/// Each protocol instance has one live hop, created away from startLoading's
/// queue (FN-09). The group holds body context across instances. Native
/// redirect policy still runs on the outer task; the private hop never follows.
final class D03ForwardHop: NSObject, URLSessionDataDelegate {
    private let queue = DispatchQueue(label: "D03ForwardHop")
    private let state = Mutex(D03ForwardState())
    private let context = Mutex<(operation: D03Operation, delivery: D02ControlledDelivery)?>(nil)

    func start(request: URLRequest, operation: D03Operation, delivery: D02ControlledDelivery) {
        queue.async {
            guard !self.state.withLock({ $0.stopped }) else { return }
            self.context.withLock { $0 = (operation, delivery) }
            let session = d03Session(delegate: self)
            let task = session.dataTask(with: request)
            self.state.withLock { $0.session = session; $0.task = task }
            task.resume()
        }
    }

    func refuse() {
        let pending = state.withLock { state in
            defer { state.pending = nil }
            return state.pending
        }
        pending?(nil)
    }

    func stop() {
        queue.async {
            let previous = self.state.withLock { state in
                defer { state = D03ForwardState(stopped: true) }
                return state
            }
            self.context.withLock { $0 = nil }
            if previous.completed {
                previous.session?.finishTasksAndInvalidate()
            } else {
                previous.session?.invalidateAndCancel()
            }
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        guard let context = context.withLock({ $0 }) else { completionHandler(nil); return }
        // An Apple proposal can contain a stream for the in-memory body we own.
        // Recover that body before crossing into the next native protocol. Use
        // Foundation's proposed method/URL/headers; do not implement HTTP policy.
        var prepared = request
        if request.httpBodyStream != nil {
            prepared.httpBodyStream = nil
            prepared.httpBody = context.operation.body.withLock { $0 }
        }
        context.operation.body.withLock { $0 = prepared.httpBody }
        context.operation.redirects.withLock { $0.append(prepared) }
        state.withLock { $0.pending = completionHandler }
        context.delivery.redirect(to: prepared, response: response)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        context.withLock { $0 }?.delivery.head(response: response)
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        context.withLock { $0 }?.delivery.bytes(data)
    }

    func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        state.withLock { $0.completed = true }
        let context = context.withLock { state in
            defer { state = nil }
            return state
        }
        context?.delivery.finish(error: error as NSError?)
        session.finishTasksAndInvalidate()
    }
}
