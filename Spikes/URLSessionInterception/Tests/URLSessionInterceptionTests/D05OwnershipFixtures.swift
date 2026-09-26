import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization

private struct D05WeakState<Value: AnyObject & Sendable>: Sendable {
    weak var value: Value?
}

final class D05WeakObject<Value: AnyObject & Sendable>: Sendable {
    private let state: Mutex<D05WeakState<Value>>
    init(_ value: Value) {
        state = Mutex(D05WeakState(value: value))
    }

    var isReleased: Bool {
        state.withLock { $0.value == nil }
    }

    var value: Value? {
        state.withLock { $0.value }
    }
}

final class D05Scenario: Sendable {
    let observations = Mutex<[String]>([])
}

/// Observation and horizon share one mutex. A tail retains this detached gate,
/// never a copied scenario pointer or an observation closure capturing it.
final class D05ObservationGate: Sendable {
    private let scenario: Mutex<D05Scenario?>
    init(_ scenario: D05Scenario?) {
        self.scenario = Mutex(scenario)
    }

    func observe(_ value: String) {
        scenario.withLock { $0?.observations.withLock { $0.append(value) } }
    }

    func detach() -> [String] {
        scenario.withLock { value in
            defer { value = nil }
            return value?.observations.withLock { $0 } ?? []
        }
    }
}

struct D05LeaseState: Sendable {
    var closed = false
    var operations: [D05ReplayOperation] = []
}

final class D05RouteLease: Sendable {
    let state = Mutex(D05LeaseState())
    let observation: D05ObservationGate

    init(_ scenario: D05Scenario?) {
        observation = D05ObservationGate(scenario)
    }

    func admit(_ operation: D05ReplayOperation) -> Bool {
        state.withLock {
            guard !$0.closed else { return false }
            $0.operations.append(operation)
            observation.observe("admit")
            return true
        }
    }

    func close() -> [String] {
        state.withLock { $0.closed = true; $0.operations = [] }
        D05Routes.entries.withLock { $0.removeAll { $0.lease === self } }
        return observation.detach()
    }
}

struct D05RouteEntry: Sendable {
    let session: URLSession
    let lease: D05RouteLease
}

final class D05LookupPause: Sendable {
    let result = Mutex<(@Sendable () -> Void)?>(nil)
    func release() {
        let action = result.withLock { state in
            defer { state = nil }
            return state
        }
        action?()
    }
}

enum D05Routes {
    static let entries = Mutex<[D05RouteEntry]>([])
    static let pause = Mutex<D05LookupPause?>(nil)

    static func resolve(_ task: URLSessionTask, completion: @escaping @Sendable (D05RouteLease?) -> Void) {
        let candidates = entries.withLock { $0 }
        guard !candidates.isEmpty else { completion(nil); return }
        let result = Mutex((remaining: candidates.count, matches: [D05RouteLease]()))
        for candidate in candidates {
            candidate.session.getAllTasks { tasks in
                let found = tasks.contains { $0 === task }
                let matches = result.withLock { state -> [D05RouteLease]? in
                    if found {
                        state.matches.append(candidate.lease)
                    }
                    state.remaining -= 1
                    return state.remaining == 0 ? state.matches : nil
                }
                guard let matches else { return }
                let selected = matches.count == 1 ? matches.first : nil
                let action: @Sendable () -> Void = { completion(selected) }
                if let pause = pause.withLock({ $0 }) {
                    pause.result.withLock { $0 = action }
                } else {
                    action()
                }
            }
        }
    }
}

final class D05RoutedProtocol: URLProtocol {
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
        guard let task else { return }
        let operation = D05ReplayOperation(delivery: delivery, task: task)
        D05Routes.resolve(task) { lease in
            // The registry snapshot predates this callback. Only the current
            // lease may admit the task; expiration must not publish a stale route.
            guard let lease, lease.admit(operation) else {
                delivery.finish(error: NSError(domain: "D05ExpiredRoute", code: 1))
                return
            }
            delivery.head()
            delivery.bytes("routed")
            delivery.finish()
        }
    }

    override func stopLoading() {
        delivery.withLock { $0 }?.stop()
    }
}

func d05RoutedSession(_ observer: D05NativeObserver, lease: D05RouteLease) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.protocolClasses = [D05RoutedProtocol.self]
    let session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
    D05Routes.entries.withLock { $0.append(D05RouteEntry(session: session, lease: lease)) }
    return session
}
