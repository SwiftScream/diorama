import DioramaHTTP
import Foundation
import HTTPTypesFoundation
import Synchronization

/// Foundation owns the non-Sendable protocol instance. All access to its client
/// after startLoading, including terminal handoff and reentrant stopLoading, is
/// serialized by the recursive lock. No caller can take the instance out.
final class SessionDelivery: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var instance: URLProtocol?
    private var cancelOperation: (@Sendable () -> Void)?
    private var stopped = false
    let task: URLSessionTask?

    init(_ instance: URLProtocol) {
        self.instance = instance
        task = instance.task
    }

    func whileOpen(_ body: () throws -> Void) rethrows {
        try lock.withLock {
            if instance != nil {
                try body()
            }
        }
    }

    func onCancel(_ action: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock {
            if instance != nil {
                cancelOperation = action
            }
            return stopped
        }
        if runNow {
            action()
        }
    }

    @discardableResult
    func stop() -> Bool {
        let (open, cancel) = lock.withLock {
            let open = instance != nil
            stopped = stopped || open
            defer { instance = nil; cancelOperation = nil }
            return (open, cancelOperation)
        }
        cancel?()
        return open
    }

    func response(_ response: URLResponse) {
        lock.withLock {
            guard let instance else { return }
            instance.client?.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
    }

    func bytes(_ data: Data) {
        lock.withLock {
            guard let instance else { return }
            instance.client?.urlProtocol(instance, didLoad: data)
        }
    }

    func finish(_ error: any Error? = nil) {
        lock.withLock {
            guard let instance else { return }
            self.instance = nil
            cancelOperation = nil
            if let error {
                instance.client?.urlProtocol(instance, didFailWithError: error)
            } else {
                instance.client?.urlProtocolDidFinishLoading(instance)
            }
        }
    }

    func deliver(_ event: HTTPReplayEvent<URLSessionFailure>) {
        switch event {
        case let .response(head, request):
            guard let url = request.head.url, let native = HTTPURLResponse(httpResponse: head.head, url: url)
            else { finish(SessionBridgeError.conversion); return }
            response(native)
        case let .bytes(bytes): self.bytes(Data(bytes))
        case .returned: finish()
        case let .infrastructureFailure(error): finish(error)
        default: finish(SessionBridgeError.unsupported)
        }
    }
}

final class SessionProtocol: URLProtocol {
    private let active = Mutex<SessionDelivery?>(nil)

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
        let delivery = SessionDelivery(self)
        active.withLock { $0 = delivery }
        guard let task else { delivery.finish(SessionBridgeError.ownership); return }
        let request = request
        SessionRoutes.resolve(task) { owner in
            guard let owner else {
                delivery.whileOpen {
                    (task.delegate as? SessionOwner)?.rejectOwnership()
                    delivery.finish(SessionBridgeError.ownership)
                }
                return
            }
            owner.start(delivery, request: request)
        }
    }

    override func stopLoading() {
        active.withLock { current in
            defer { current = nil }
            return current
        }?.stop()
    }
}

enum SessionRoutes {
    struct Entry: Sendable {
        let session: URLSession
        let owner: SessionOwner
    }

    static let entries = Mutex<[Entry]>([])

    static func resolve(_ task: URLSessionTask, completion: @escaping @Sendable (SessionOwner?) -> Void) {
        let entries = entries.withLock { $0 }
        let candidates = entries.filter { $0.owner.status(of: task) == .created }
        guard candidates.count == 1, let entry = candidates.first else { completion(nil); return }
        entry.owner.resolve(task, in: entry.session, completion: completion)
    }
}
