import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization
import Testing

private let ownershipURL = URL(string: "http://d01.invalid/bodyless-get")!
private let ownershipRouteHeader = "X-Diorama-D01-Route"

private enum OwnershipOriginProbe {
    static let requests = Mutex(0)

    static func reset() {
        requests.withLock { $0 = 0 }
    }
}

private final class OwnershipOriginProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http" || request.url?.scheme == "https"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        OwnershipOriginProbe.requests.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: NSError(domain: "DioramaD01UnexpectedOrigin", code: 1))
    }

    override func stopLoading() {}
}

private struct OwnershipEntry: Sendable {
    let session: URLSession
    let name: String
}

private struct OwnershipLookup: Sendable {
    var remaining: Int
    var matches: [String] = []
}

private struct OwnershipObservation: Sendable {
    let task: ObjectIdentifier?
    let name: String?
    let taskIdentifier: Int
}

private enum OwnershipProbe {
    static let entries = Mutex<[OwnershipEntry]>([])
    static let observations = Mutex<[OwnershipObservation]>([])

    static func reset() {
        entries.withLock { $0 = [] }
        observations.withLock { $0 = [] }
    }

    static func register(_ session: URLSession, name: String) {
        entries.withLock { $0.append(OwnershipEntry(session: session, name: name)) }
    }

    static func expire(_ session: URLSession) {
        entries.withLock { $0.removeAll { $0.session === session } }
    }

    static func resolve(
        task: URLSessionTask,
        completion: @Sendable @escaping (String?) -> Void)
    {
        let candidates = entries.withLock { $0 }
        guard !candidates.isEmpty else {
            completion(nil)
            return
        }
        let lookup = Mutex(OwnershipLookup(remaining: candidates.count))
        for candidate in candidates {
            candidate.session.getAllTasks { tasks in
                let found = tasks.contains { $0 === task }
                let result = lookup.withLock { state -> [String]? in
                    if found {
                        state.matches.append(candidate.name)
                    }
                    state.remaining -= 1
                    return state.remaining == 0 ? state.matches : nil
                }
                if let result {
                    completion(result.count == 1 ? result[0] : nil)
                }
            }
        }
    }

    static func observe(task: URLSessionTask?, name: String?, taskIdentifier: Int) {
        observations.withLock {
            $0.append(OwnershipObservation(
                task: task.map(ObjectIdentifier.init),
                name: name,
                taskIdentifier: taskIdentifier))
        }
    }
}

private final class TaskOwnershipProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http" || request.url?.scheme == "https"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let task else {
            OwnershipProbe.observe(task: nil, name: nil, taskIdentifier: -1)
            return
        }
        let taskIdentifier = task.taskIdentifier
        OwnershipProbe.resolve(task: task) { name in
            OwnershipProbe.observe(task: task, name: name, taskIdentifier: taskIdentifier)
        }
    }

    override func stopLoading() {}
}

/// This state is created for one bridge and accessed only through its mutex.
private struct OwnershipDeliveryState: @unchecked Sendable {
    var protocolInstance: RoutedOwnershipProtocol?
}

/// URLProtocol is not Sendable. This test-only bridge transfers the one terminal
/// callback right under a mutex, then releases its protocol reference. It tests
/// asynchronous routing; cancellation during callback delivery remains unproven.
private final class OwnershipDelivery: @unchecked Sendable {
    private let state: Mutex<OwnershipDeliveryState>

    init(_ protocolInstance: RoutedOwnershipProtocol) {
        state = Mutex(OwnershipDeliveryState(protocolInstance: protocolInstance))
    }

    func finish(name: String?) {
        let protocolInstance = state.withLock { state -> RoutedOwnershipProtocol? in
            defer { state.protocolInstance = nil }
            return state.protocolInstance
        }
        protocolInstance?.emit(name: name)
    }

    func stop() {
        state.withLock { $0.protocolInstance = nil }
    }
}

private final class RoutedOwnershipProtocol: URLProtocol {
    private let delivery = Mutex<OwnershipDelivery?>(nil)

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http" || request.url?.scheme == "https"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let task else {
            emit(name: nil)
            return
        }
        let bridge = OwnershipDelivery(self)
        delivery.withLock { $0 = bridge }
        OwnershipProbe.resolve(task: task) { name in
            bridge.finish(name: name)
        }
    }

    override func stopLoading() {
        let bridge = delivery.withLock { state -> OwnershipDelivery? in
            defer { state = nil }
            return state
        }
        bridge?.stop()
    }

    func emit(name: String?) {
        guard let name else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "DioramaD01Ownership", code: 1))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(name.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized)
struct TaskOwnershipTests {
    @Test
    func `task ownership lookup matches concurrent sessions without request metadata`() async {
        OwnershipProbe.reset()
        OwnershipOriginProbe.reset()
        let first = ownershipSession()
        let second = ownershipSession()
        OwnershipProbe.register(first, name: "first")
        OwnershipProbe.register(second, name: "second")
        defer {
            first.invalidateAndCancel()
            second.invalidateAndCancel()
            OwnershipProbe.reset()
        }

        let firstTask = first.dataTask(with: ownershipURL)
        let secondTask = second.dataTask(with: ownershipURL)
        defer {
            firstTask.cancel()
            secondTask.cancel()
        }
        firstTask.resume()
        secondTask.resume()

        #expect(await waitForOwnershipObservations(2))
        let observations = OwnershipProbe.observations.withLock { $0 }
        #expect(observations.first { $0.task == ObjectIdentifier(firstTask) }?.name == "first")
        #expect(observations.first { $0.task == ObjectIdentifier(secondTask) }?.name == "second")
        #expect(observations.allSatisfy { $0.taskIdentifier > 0 })
        #expect(OwnershipOriginProbe.requests.withLock { $0 } == 0)
    }

    @Test
    func `task ownership lookup ignores caller headers and separates overlapping tasks`() async {
        OwnershipProbe.reset()
        OwnershipOriginProbe.reset()
        let first = ownershipSession()
        let second = ownershipSession()
        OwnershipProbe.register(first, name: "first")
        OwnershipProbe.register(second, name: "second")
        defer {
            first.invalidateAndCancel()
            second.invalidateAndCancel()
            OwnershipProbe.reset()
        }
        var request = URLRequest(url: ownershipURL)
        request.setValue("second", forHTTPHeaderField: ownershipRouteHeader)

        let firstA = first.dataTask(with: request)
        let firstB = first.dataTask(with: ownershipURL)
        let secondA = second.dataTask(with: ownershipURL)
        defer {
            firstA.cancel()
            firstB.cancel()
            secondA.cancel()
        }
        firstA.resume()
        firstB.resume()
        secondA.resume()

        #expect(await waitForOwnershipObservations(3))
        let observations = OwnershipProbe.observations.withLock { $0 }
        #expect(observations.first { $0.task == ObjectIdentifier(firstA) }?.name == "first")
        #expect(observations.first { $0.task == ObjectIdentifier(firstB) }?.name == "first")
        #expect(observations.first { $0.task == ObjectIdentifier(secondA) }?.name == "second")
        #expect(OwnershipOriginProbe.requests.withLock { $0 } == 0)
    }

    @Test
    func `expired task ownership has no match and does not reach the origin`() async {
        OwnershipProbe.reset()
        OwnershipOriginProbe.reset()
        let session = ownershipSession()
        OwnershipProbe.register(session, name: "expired")
        OwnershipProbe.expire(session)
        defer {
            session.invalidateAndCancel()
            OwnershipProbe.reset()
        }

        let task = session.dataTask(with: ownershipURL)
        defer { task.cancel() }
        task.resume()

        #expect(await waitForOwnershipObservations(1))
        let observation = OwnershipProbe.observations.withLock { $0.first }
        #expect(observation?.task == ObjectIdentifier(task))
        #expect(observation?.name == nil)
        #expect(OwnershipOriginProbe.requests.withLock { $0 } == 0)
    }

    @Test
    func `task ownership delivers independent bodyless GET responses`() async throws {
        OwnershipProbe.reset()
        OwnershipOriginProbe.reset()
        let first = routedOwnershipSession()
        let second = routedOwnershipSession()
        OwnershipProbe.register(first, name: "first")
        OwnershipProbe.register(second, name: "second")
        defer {
            first.invalidateAndCancel()
            second.invalidateAndCancel()
            OwnershipProbe.reset()
        }
        var callerRequest = URLRequest(url: ownershipURL)
        callerRequest.setValue("second", forHTTPHeaderField: ownershipRouteHeader)

        async let firstBody = routedBody(from: first, request: callerRequest)
        async let secondBody = routedBody(from: second, request: URLRequest(url: ownershipURL))
        #expect(try await firstBody == "first")
        #expect(try await secondBody == "second")
        #expect(OwnershipOriginProbe.requests.withLock { $0 } == 0)
    }

    @Test
    func `expired task ownership rejects without origin access`() async {
        OwnershipProbe.reset()
        OwnershipOriginProbe.reset()
        let session = routedOwnershipSession()
        OwnershipProbe.register(session, name: "expired")
        OwnershipProbe.expire(session)
        defer {
            session.invalidateAndCancel()
            OwnershipProbe.reset()
        }

        do {
            _ = try await routedBody(from: session, request: URLRequest(url: ownershipURL))
            Issue.record("An expired ownership route succeeded")
        } catch {}
        #expect(OwnershipOriginProbe.requests.withLock { $0 } == 0)
    }

    private func waitForOwnershipObservations(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if OwnershipProbe.observations.withLock({ $0.count }) >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func ownershipSession() -> URLSession {
        let configuration = ownershipConfigurationWithOrigin()
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.protocolClasses = [TaskOwnershipProtocol.self] + (configuration.protocolClasses ?? [])
        return URLSession(configuration: configuration)
    }

    private func routedOwnershipSession() -> URLSession {
        let configuration = ownershipConfigurationWithOrigin()
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.protocolClasses = [RoutedOwnershipProtocol.self] + (configuration.protocolClasses ?? [])
        return URLSession(configuration: configuration)
    }

    private func routedBody(from session: URLSession, request: URLRequest) async throws -> String {
        let (data, _) = try await session.data(for: request)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private func ownershipConfigurationWithOrigin() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OwnershipOriginProtocol.self]
        return configuration
    }
}
