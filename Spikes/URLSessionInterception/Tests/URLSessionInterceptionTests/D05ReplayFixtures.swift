import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization

/// A test-controlled synchronous consumer callback. The test always releases it
/// in cleanup; waiting for it is not a production timeout or quiescence test.
final class D05CallbackBlock: Sendable {
    let entered = Mutex(false)
    private let semaphore = DispatchSemaphore(value: 0)

    func enter() {
        entered.withLock { $0 = true }
        semaphore.wait()
    }

    func release() {
        semaphore.signal()
    }
}

struct D05NativeEvents: Sendable {
    var sequence: [String] = []
    var body = Data()
    var errorCode: Int?
    var completions = 0
    var invalidated = false
    var pending: (@Sendable () -> Void)?
}

private struct D05DecisionHandlers: Sendable {
    let answer: @Sendable () -> Void
    let abort: @Sendable () -> Void
}

/// A retained consumer answer owns only this empty box after cleanup. Native
/// callbacks are released exactly once, on an independent serial executor.
final class D05PendingDecision: Sendable {
    private let handlers: Mutex<D05DecisionHandlers?>
    private let queue: DispatchQueue

    init(queue: DispatchQueue, answer: @escaping @Sendable () -> Void, abort: @escaping @Sendable () -> Void) {
        self.queue = queue
        handlers = Mutex(D05DecisionHandlers(answer: answer, abort: abort))
    }

    func answer() {
        queue.async {
            let handlers = self.take()
            handlers?.answer()
        }
    }

    func abort() {
        let handlers = take()
        queue.async { handlers?.abort() }
    }

    private func take() -> D05DecisionHandlers? {
        handlers.withLock { state in
            defer { state = nil }
            return state
        }
    }
}

private struct D05DecisionState: Sendable {
    var closed = false
    var pending: [D05PendingDecision] = []
}

/// Consumer and internal decision observer are combined in this isolated
/// fixture. Late consumer answers check the operation before calling Foundation.
final class D05NativeObserver: NSObject, URLSessionDataDelegate {
    let events = Mutex(D05NativeEvents())
    let block: D05CallbackBlock?
    let blockAt: String
    let holdDecision: Bool
    let redirectChoice: String
    let liveOperations = Mutex<[ObjectIdentifier: D05LiveOperation]>([:])
    private let decisionQueue = DispatchQueue(label: "D05NativeDecision")
    private let decisions = Mutex(D05DecisionState())

    init(block: D05CallbackBlock? = nil, blockAt: String = "", holdDecision: Bool = false,
         redirectChoice: String = "refuse")
    {
        self.block = block
        self.blockAt = blockAt
        self.holdDecision = holdDecision
        self.redirectChoice = redirectChoice
    }

    func event(_ name: String) {
        events.withLock { $0.sequence.append(name) }
        if blockAt == name {
            block?.enter()
            events.withLock { $0.sequence.append("\(name)Returned") }
        }
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive _: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        event("head")
        decide(answer: { completionHandler(.allow) }, abort: { completionHandler(.cancel) })
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        events.withLock { $0.body.append(data) }
        event("body")
    }

    func urlSession(_: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        event("redirect")
        let operation = liveOperations.withLock { $0[ObjectIdentifier(task)] }
        let choice = redirectChoice == "follow" ? request : nil
        decide(answer: {
            operation?.prepareRedirect(choice)
            completionHandler(choice)
            if choice == nil {
                operation?.refuseRedirect()
            }
        }, abort: { completionHandler(nil) })
    }

    func urlSession(_: URLSession, task: URLSessionTask, didReceive _: URLAuthenticationChallenge,
                    completionHandler: @escaping D04Answer)
    {
        event("challenge")
        let operation = liveOperations.withLock { $0[ObjectIdentifier(task)] }
        let sender = operation?.sender.withLock { $0 }
        decide(answer: {
                   let disposition: URLSession.AuthChallengeDisposition = sender == nil ?
                       .performDefaultHandling : .useCredential
                   let credential = sender == nil ? nil : d04Credential()
                   completionHandler(disposition, credential)
                   sender?.resolve(disposition, credential: credential)
                   operation?.sender.withLock { $0 = nil }
               },
               abort: { completionHandler(.cancelAuthenticationChallenge, nil) })
    }

    private func decide(answer: @escaping @Sendable () -> Void, abort: @escaping @Sendable () -> Void) {
        guard holdDecision else { answer(); return }
        let decision = D05PendingDecision(queue: decisionQueue, answer: answer, abort: abort)
        let closed = decisions.withLock { state in
            if !state.closed {
                state.pending.append(decision)
            }
            return state.closed
        }
        if closed {
            decision.abort()
        }
        events.withLock { $0.pending = { decision.answer() } }
    }

    func abortDecisions() async {
        closeDecisionAdmission()
        await withCheckedContinuation { continuation in
            decisionQueue.async { continuation.resume() }
        }
    }

    func closeDecisionAdmission() {
        let decisions = decisions.withLock { state in
            defer { state.closed = true; state.pending = [] }
            return state.pending
        }
        for decision in decisions {
            decision.abort()
        }
    }

    func answerPending() {
        let pending = events.withLock { state in
            defer { state.pending = nil }
            return state.pending
        }
        pending?()
    }

    func complete(data: Data?, error: (any Error)?) {
        events.withLock {
            if let data {
                $0.body = data
            }
            $0.errorCode = (error as NSError?)?.code
            $0.completions += 1
        }
        event("completion")
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        liveOperations.withLock { $0[ObjectIdentifier(task)] }?.finish()
        complete(data: nil, error: error)
    }

    func urlSession(_: URLSession, didBecomeInvalidWithError _: (any Error)?) {
        event("invalidation")
        events.withLock { $0.invalidated = true }
    }
}

final class D05ReplayOperation: Sendable {
    let delivery: D02ControlledDelivery
    let task: URLSessionTask
    let stopped = Mutex(false)

    init(delivery: D02ControlledDelivery, task: URLSessionTask) {
        self.delivery = delivery
        self.task = task
    }

    func stop() {
        stopped.withLock { $0 = true }
        delivery.stop()
    }
}

final class D05ReplayProtocol: URLProtocol {
    static let operations = Mutex<[ObjectIdentifier: D05ReplayOperation]>([:])
    private let operation = Mutex<D05ReplayOperation?>(nil)

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
        let operation = D05ReplayOperation(delivery: D02ControlledDelivery(self), task: task)
        self.operation.withLock { $0 = operation }
        Self.operations.withLock { $0[ObjectIdentifier(task)] = operation }
    }

    override func stopLoading() {
        operation.withLock { $0 }?.stop()
    }
}

func d05ReplaySession(_ observer: D05NativeObserver, width: Int = 1) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.protocolClasses = [D05ReplayProtocol.self]
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = width
    return URLSession(configuration: configuration, delegate: observer, delegateQueue: queue)
}

func d05QueueBarrier(_ queue: OperationQueue) async {
    await withCheckedContinuation { continuation in
        queue.addBarrierBlock { continuation.resume() }
    }
}

func d05Tasks(_ session: URLSession) async -> [URLSessionTask] {
    await withCheckedContinuation { continuation in
        session.getAllTasks { continuation.resume(returning: $0) }
    }
}

/// No consumer-owned live task uses this path. Foundation APIs are invoked from
/// the test's async context, outside startLoading/stopLoading (FN-09).
func d05CloseReplay(_ session: URLSession, observer: D05NativeObserver) async -> Bool {
    let operations = D05ReplayProtocol.operations.withLock { state in
        defer { state = [:] }
        return Array(state.values)
    }
    for operation in operations {
        operation.stop()
    }
    let tasks = await d05Tasks(session)
    for task in tasks {
        task.cancel()
    }
    await observer.abortDecisions()
    session.finishTasksAndInvalidate()
    // This wait observes a native acknowledgement. The watchdog only fails the
    // experiment; expiration never counts as successful quiescence.
    guard await d02Eventually({ observer.events.withLock { $0.invalidated } }) else { return false }
    await d05QueueBarrier(session.delegateQueue)
    return true
}
