import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization

struct D03RedirectObservation: Sendable {
    var proposals: [URLRequest] = []
    var statuses: [Int] = []
    var pending: (@Sendable (URLRequest?) -> Void)?
    var body = Data()
    var response: HTTPURLResponse?
    var error: NSError?
    var completions = 0
}

final class D03RedirectConsumer: NSObject, URLSessionDataDelegate {
    let mode: String
    let observation = Mutex(D03RedirectObservation())
    let decisionObserver = Mutex<(@Sendable (URLSessionTask, URLRequest?) -> Void)?>(nil)
    let decisionPreparation = Mutex<(@Sendable (URLSessionTask, URLRequest?) -> Void)?>(nil)

    init(mode: String = "follow") {
        self.mode = mode
    }

    func urlSession(_: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        observation.withLock {
            $0.proposals.append(request)
            $0.statuses.append(response.statusCode)
        }
        let answer: @Sendable (URLRequest?) -> Void = { choice in
            self.decisionPreparation.withLock { $0 }?(task, choice)
            completionHandler(choice)
            self.decisionObserver.withLock { $0 }?(task, choice)
        }
        switch mode {
        case "pending": observation.withLock { $0.pending = answer }
        case "refuse": answer(nil)
        case "cancel": task.cancel(); answer(nil)
        case "modify", "modifyBody":
            var modified = request
            modified.url = request.url?.deletingLastPathComponent().appendingPathComponent("modified")
            modified.setValue("consumer", forHTTPHeaderField: "X-D03-Modified")
            if mode == "modifyBody" {
                modified.httpMethod = "POST"
                modified.httpBodyStream = nil
                modified.httpBody = Data("changed".utf8)
            }
            answer(modified)
        default: answer(request)
        }
    }

    func decide(_ request: URLRequest?) {
        let pending = observation.withLock { state in
            defer { state.pending = nil }
            return state.pending
        }
        pending?(request)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        observation.withLock { $0.response = response as? HTTPURLResponse }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        observation.withLock { $0.body.append(data) }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        complete(data: nil, response: nil, error: error)
    }

    func complete(data: Data?, response: URLResponse?, error: (any Error)?) {
        observation.withLock {
            if let data {
                $0.body = data
            }
            if let response {
                $0.response = response as? HTTPURLResponse
            }
            $0.error = error as NSError?
            $0.completions += 1
        }
    }
}

struct D03ProtocolVisit: Sendable {
    let instance: Int
    let task: ObjectIdentifier?
    let request: URLRequest
    let owner: String?
    let operation: ObjectIdentifier
}

struct D03Route: Sendable {
    let session: URLSession
    let name: String
    var scenario = "single"
    var delay: Duration = .zero
}

/// The grouped interaction outlives individual protocol instances. No request
/// properties or HTTP headers carry this object or its identity.
final class D03Operation: Sendable {
    let visits = Mutex(0)
    let deliveryTimes = Mutex<[ContinuousClock.Instant]>([])
    let body = Mutex<Data?>(nil)
    let redirects = Mutex<[URLRequest]>([])
    let forwarding = Mutex<D03ForwardHop?>(nil)
}

enum D03RedirectProbe {
    static let routes = Mutex<[D03Route]>([])
    static let visits = Mutex<[D03ProtocolVisit]>([])
    static let stops = Mutex<[Int]>([])
    static let nextInstance = Mutex(0)
    static let deliveries = Mutex<[ObjectIdentifier: D02ControlledDelivery]>([:])
    static let operations = Mutex<[ObjectIdentifier: D03Operation]>([:])

    static func operation(for task: URLSessionTask) -> D03Operation {
        operations.withLock { operations in
            let key = ObjectIdentifier(task)
            if let existing = operations[key] {
                return existing
            }
            let created = D03Operation()
            created.body.withLock { $0 = task.originalRequest?.httpBody }
            operations[key] = created
            return created
        }
    }

    static func reset() {
        routes.withLock { $0 = [] }
        visits.withLock { $0 = [] }
        stops.withLock { $0 = [] }
        deliveries.withLock { $0 = [:] }
        operations.withLock { $0 = [:] }
    }
}

final class D03RedirectProtocol: URLProtocol {
    private let instanceNumber = D03RedirectProbe.nextInstance.withLock { $0 += 1; return $0 }
    private let delivery = Mutex<D02ControlledDelivery?>(nil)
    private let forwarder = D03ForwardHop()

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
        let instance = instanceNumber
        let request = request
        guard let task else {
            delivery.finish(error: NSError(domain: "D03MissingTask", code: 1))
            return
        }
        let operation = D03RedirectProbe.operation(for: task)
        D03RedirectProbe.deliveries.withLock { $0[ObjectIdentifier(task)] = delivery }
        // D01's asynchronous ownership lookup, extended to every redirect hop.
        let candidates = D03RedirectProbe.routes.withLock { $0 }
        let forwarder = forwarder
        let lookup = Mutex((remaining: candidates.count, matches: [String]()))
        guard !candidates.isEmpty else {
            delivery.finish(error: NSError(domain: "D03MissingRoute", code: 1))
            return
        }
        for route in candidates {
            route.session.getAllTasks { tasks in
                let found = tasks.contains { $0 === task }
                let matches = lookup.withLock { state -> [String]? in
                    if found {
                        state.matches.append(route.name)
                    }
                    state.remaining -= 1
                    return state.remaining == 0 ? state.matches : nil
                }
                guard let matches else { return }
                let owner = matches.count == 1 ? matches.first : nil
                D03RedirectProbe.visits.withLock {
                    $0.append(D03ProtocolVisit(instance: instance, task: ObjectIdentifier(task),
                                               request: request, owner: owner, operation: ObjectIdentifier(operation)))
                }
                guard let owner, let selected = candidates.first(where: { $0.name == owner }) else {
                    delivery.finish(error: NSError(domain: "D03MissingRoute", code: 1))
                    return
                }
                if selected.scenario == "forward" {
                    var prepared = request
                    prepared.httpBodyStream = nil
                    prepared.httpBody = request.httpBody ?? operation.body.withLock { $0 }
                    operation.forwarding.withLock { $0 = forwarder }
                    forwarder.start(request: prepared, operation: operation, delivery: delivery)
                } else {
                    d03Emit(request: request, route: selected, operation: operation, delivery: delivery)
                }
            }
        }
    }

    override func stopLoading() {
        D03RedirectProbe.stops.withLock { $0.append(instanceNumber) }
        delivery.withLock { $0 }?.stop()
        forwarder.stop()
    }
}

private func d03Emit(request: URLRequest, route: D03Route, operation: D03Operation, delivery: D02ControlledDelivery) {
    guard let url = request.url else { return }
    let visits = operation.visits.withLock { $0 += 1; return $0 }
    // Bound the experiment if Foundation fails to enforce its native limit.
    guard visits <= 25 else {
        delivery.finish(error: NSError(domain: "D03ProbeSafetyLimit", code: 1))
        return
    }
    if url.path == "/start" || url.path == "/hop" {
        let path = route.scenario == "loop" ? "start" :
            route.scenario == "multiple" && url.path == "/start" ? "hop" : "final"
        let next = url.deletingLastPathComponent().appendingPathComponent(path)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": next.absoluteString])!
        delivery.redirect(to: URLRequest(url: next), response: response)
    } else if url.path == "/final" || url.path == "/modified" {
        Task {
            do { try await Task.sleep(for: route.delay) } catch { return }
            operation.deliveryTimes.withLock { $0.append(.now) }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            delivery.head(response: response)
            delivery.bytes(Data("final".utf8))
            delivery.finish()
        }
    } else {
        delivery.finish(error: NSError(domain: "D03IncompatibleContinuation", code: 1))
    }
}

func d03Session(delegate: (any URLSessionDelegate)? = nil, intercepted: Bool = false) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = d02WatchdogSeconds
    if intercepted {
        configuration.protocolClasses = [D03RedirectProtocol.self]
    }
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
}
