import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization

struct D05ForwardSetup: Sendable {
    let observation: D05ObservationGate
    var customSource = true
    var startBlock: D05CallbackBlock?
}

private struct D05ForwardState: Sendable {
    var session: URLSession?
    var task: URLSessionTask?
    var stopped = false
    var completed = false
    var invalidated = false
    var cancelCalls = 0
    var weakSession: D05WeakObject<URLSession>?
    var redirect: (@Sendable (URLRequest?) -> Void)?
    var sender: D04Sender?
}

/// A private transport owns its delegate until invalidation. Its only scenario
/// access is the detachable observation gate. start/stop/complete use a serial
/// executor independent of Foundation's shared work queue (FN-09).
final class D05ForwardTail: NSObject, URLSessionDataDelegate {
    private let queue = DispatchQueue(label: "D05ForwardTail")
    private let state = Mutex(D05ForwardState())
    let delivery: D02ControlledDelivery
    let setup: D05ForwardSetup
    let operation: D05LiveOperation

    init(delivery: D02ControlledDelivery, operation: D05LiveOperation) {
        self.delivery = delivery
        self.operation = operation
        setup = operation.setup
    }

    var stopped: Bool {
        state.withLock { $0.stopped }
    }

    var invalidated: Bool {
        state.withLock { $0.invalidated }
    }

    var cancelCalls: Int {
        state.withLock { $0.cancelCalls }
    }

    var weakSession: D05WeakObject<URLSession>? {
        state.withLock { $0.weakSession }
    }

    func start(_ request: URLRequest) {
        queue.async {
            self.setup.startBlock?.enter()
            guard !self.stopped else { return }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            if self.setup.customSource {
                configuration.protocolClasses = [D05LiveSourceProtocol.self]
            }
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: request)
            self.state.withLock {
                $0.session = session
                $0.task = task
                $0.weakSession = D05WeakObject(session)
            }
            task.resume()
        }
    }

    func stop() {
        delivery.stop()
        // Own each private decision in its transport, independently of outer
        // completion and any replacement protocol instance after a redirect.
        let sender = state.withLock { state in
            defer { state.sender = nil }
            return state.sender
        }
        if operation.task?.state == .canceling {
            operation.abortDecisions()
        }
        if operation.isCurrent(self) {
            operation.finish()
        }
        state.withLock { $0.stopped = true }
        queue.async {
            let native = self.state.withLock { state -> D05TransportStop in
                if !state.completed, state.task != nil {
                    state.cancelCalls += 1
                }
                defer { state.redirect = nil }
                return D05TransportStop(session: state.session, task: state.completed ? nil : state.task,
                                        redirect: state.redirect)
            }
            // An unanswered native decision can retain a canceled transport.
            // Release it as runtime cleanup before canceling the superseded hop.
            native.redirect?(nil)
            sender?.resolve(.cancelAuthenticationChallenge, credential: nil)
            native.task?.cancel()
            native.session?.finishTasksAndInvalidate()
        }
    }

    func drainExecutor() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    func refuseRedirect() {
        queue.async {
            let answer = self.state.withLock { state in
                defer { state.redirect = nil }
                return state.redirect
            }
            answer?(nil)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        setup.observation.observe("redirect")
        state.withLock { $0.redirect = completionHandler }
        delivery.redirect(to: request, response: response)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping D04Answer)
    {
        setup.observation.observe("challenge")
        let sender = D04Sender(nativeAnswer: completionHandler) { _ in }
        state.withLock { $0.sender = sender }
        operation.sender.withLock { $0 = sender }
        delivery.challenge(URLAuthenticationChallenge(authenticationChallenge: challenge, sender: sender))
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        if operation.isCurrent(self) {
            setup.observation.observe("head")
        }
        delivery.head(response: response)
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        if operation.isCurrent(self) {
            setup.observation.observe("body")
        }
        delivery.bytes(data)
    }

    func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        state.withLock { $0.completed = true; $0.redirect = nil; $0.sender = nil }
        if operation.isCurrent(self) {
            setup.observation.observe("completion")
            delivery.finish(error: error as NSError?)
            operation.finish()
        }
        queue.async { session.finishTasksAndInvalidate() }
    }

    func urlSession(_: URLSession, didBecomeInvalidWithError _: (any Error)?) {
        state.withLock {
            $0.session = nil
            $0.task = nil
            $0.invalidated = true
            $0.redirect = nil
            $0.sender = nil
        }
    }
}

final class D05ForwardProtocol: URLProtocol {
    static let setup = Mutex<(configuration: D05ForwardSetup, observer: D05NativeObserver)?>(nil)
    static let continuations = Mutex<[ObjectIdentifier: D05WeakObject<D05LiveOperation>]>([:])
    static let latest = Mutex<D05ForwardTail?>(nil)
    private let tail = Mutex<D05ForwardTail?>(nil)

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
        guard let task else { return }
        let key = ObjectIdentifier(task)
        let operation: D05LiveOperation
        if let existing = Self.continuations.withLock({ $0[key]?.value }), existing.task === task {
            operation = existing
        } else {
            guard let setup = Self.setup.withLock({ $0 }) else {
                client?.urlProtocol(self, didFailWithError: NSError(domain: "D05ExpiredRoute", code: 1))
                return
            }
            operation = D05LiveOperation(task: task, setup: setup.configuration, owner: setup.observer)
            setup.observer.liveOperations.withLock { $0[key] = operation }
            Self.continuations.withLock { $0[key] = D05WeakObject(operation) }
        }
        let tail = D05ForwardTail(delivery: D02ControlledDelivery(self), operation: operation)
        self.tail.withLock { $0 = tail }
        Self.latest.withLock { $0 = tail }
        tail.start(operation.attach(tail, request: request))
    }

    override func stopLoading() {
        tail.withLock { $0 }?.stop()
    }
}

final class D05LiveSourceProtocol: URLProtocol {
    static let active = Mutex<D02ControlledDelivery?>(nil)
    private let delivery = Mutex<D02ControlledDelivery?>(nil)
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
        let delivery = D02ControlledDelivery(self)
        self.delivery.withLock { $0 = delivery }
        Self.active.withLock { $0 = delivery }
    }

    override func stopLoading() {
        delivery.withLock { $0 }?.stop()
    }
}

func d05ForwardSession(_ observer: D05NativeObserver, setup: D05ForwardSetup) -> URLSession {
    D05ForwardProtocol.setup.withLock { $0 = (setup, observer) }
    D05ForwardProtocol.latest.withLock { $0 = nil }
    D05LiveSourceProtocol.active.withLock { $0 = nil }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.protocolClasses = [D05ForwardProtocol.self]
    return URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
}

/// The horizon does not await a consumer-owned live task. This fixture closes
/// observation and new routing synchronously, then starts graceful invalidation.
func d05LiveHorizon(_ session: URLSession, observation: D05ObservationGate) -> [String] {
    let frozen = observation.detach()
    D05ForwardProtocol.setup.withLock { $0 = nil }
    session.finishTasksAndInvalidate()
    return frozen
}

func d05ResetForwarding() {
    D05ForwardProtocol.setup.withLock { $0 = nil }
    D05ForwardProtocol.latest.withLock { $0 = nil }
    D05LiveSourceProtocol.active.withLock { $0 = nil }
}

private struct D05TransportStop: Sendable {
    let session: URLSession?
    let task: URLSessionTask?
    let redirect: (@Sendable (URLRequest?) -> Void)?
}
