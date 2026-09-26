import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization
import Testing

private let routeHeader = "X-Diorama-D01-Route"
private let forwardingProperty = "DioramaD01Forwarding"
private let testURL = URL(string: "http://d01.invalid/bodyless-get")!

private enum Route: Sendable {
    case replay(String)
}

private struct ProbeState: Sendable {
    var routes: [String: Route] = [:]
    var interceptions: [String: Int] = [:]
    var rejectedRequests = 0
    var originRequests = 0
    var originSawRouteHeader = false
    var interceptedHeaders: [[String: String]] = []
    var interceptedForwardMarker = false
}

private enum ProbeStore {
    static let state = Mutex(ProbeState())

    static func reset() {
        state.withLock { $0 = ProbeState() }
    }

    static func register(_ token: String, route: Route) {
        state.withLock { $0.routes[token] = route }
    }

    static func expire(_ token: String) {
        state.withLock { _ = $0.routes.removeValue(forKey: token) }
    }

    static func resolve(_ token: String?) -> Route? {
        state.withLock { state in
            guard let token, let route = state.routes[token] else {
                state.rejectedRequests += 1
                return nil
            }
            state.interceptions[token, default: 0] += 1
            return route
        }
    }

    static func observed(_ request: URLRequest) {
        state.withLock { state in
            state.interceptedHeaders.append(request.allHTTPHeaderFields ?? [:])
            state.interceptedForwardMarker = URLProtocol.property(forKey: forwardingProperty, in: request) != nil
        }
    }

    static func originReceived(_ request: URLRequest) {
        state.withLock { state in
            state.originRequests += 1
            state.originSawRouteHeader = request.value(forHTTPHeaderField: routeHeader) != nil
        }
    }

    static var snapshot: ProbeState {
        state.withLock { $0 }
    }
}

private final class InterceptingProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return URLProtocol.property(forKey: forwardingProperty, in: request) == nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        ProbeStore.observed(request)
        let token = request.value(forHTTPHeaderField: routeHeader)
        guard let route = ProbeStore.resolve(token) else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "DioramaD01Route", code: 1))
            return
        }

        switch route {
        case let .replay(body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Cache-Control": "public, max-age=3600"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class OriginProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http" || request.url?.scheme == "https"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        ProbeStore.originReceived(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("origin".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ConsumerProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http" || request.url?.scheme == "https"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        ProbeStore.originReceived(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("consumer".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum SetupError: Error {
    case reservedHeaderCollision
}

private func instrumentedSession(
    token: String?,
    configuration: URLSessionConfiguration = .ephemeral) throws -> URLSession
{
    if configuration.httpAdditionalHeaders?.keys.contains(where: {
        ($0 as? String)?.caseInsensitiveCompare(routeHeader) == .orderedSame
    }) == true {
        throw SetupError.reservedHeaderCollision
    }
    guard let copy = configuration.copy() as? URLSessionConfiguration else {
        preconditionFailure("URLSessionConfiguration.copy returned another type")
    }
    copy.urlCache = nil
    copy.requestCachePolicy = .reloadIgnoringLocalCacheData
    copy.protocolClasses = [InterceptingProtocol.self] + (configuration.protocolClasses ?? [])
    if let token {
        var headers = copy.httpAdditionalHeaders ?? [:]
        headers[routeHeader] = token
        copy.httpAdditionalHeaders = headers
    }
    return URLSession(configuration: copy)
}

private func body(from session: URLSession, request: URLRequest = URLRequest(url: testURL)) async throws -> String {
    let (data, _) = try await session.data(for: request)
    return String(bytes: data, encoding: .utf8) ?? ""
}

@Suite(.serialized)
struct InterceptionTests {
    @Test
    func `two instrumented sessions route independently`() async throws {
        ProbeStore.reset()
        ProbeStore.register("alpha", route: .replay("first"))
        ProbeStore.register("beta", route: .replay("second"))
        let first = try instrumentedSession(token: "alpha")
        let second = try instrumentedSession(token: "beta")
        defer {
            first.invalidateAndCancel()
            second.invalidateAndCancel()
        }

        let firstBody = try? await body(from: first)
        let secondBody = try? await body(from: second)
        withKnownLinuxIssue("FN-04: configuration headers are unavailable at custom interception") {
            #expect(firstBody == "first")
            #expect(ProbeStore.snapshot.interceptedHeaders.first?[routeHeader] == "alpha")
            #expect(secondBody == "second")
            #expect(ProbeStore.snapshot.interceptions == ["alpha": 1, "beta": 1])
        }
        #expect(ProbeStore.snapshot.originRequests == 0)
    }

    @Test
    func `configuration is copied and consumer protocol stays behind interceptor`() async throws {
        ProbeStore.reset()
        ProbeStore.register("ordered", route: .replay("intercepted"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsumerProtocol.self]
        let session = try instrumentedSession(token: nil, configuration: configuration)
        defer { session.invalidateAndCancel() }
        configuration.protocolClasses = [OriginProtocol.self]
        var request = URLRequest(url: testURL)
        request.setValue("ordered", forHTTPHeaderField: routeHeader)

        #expect(try await body(from: session, request: request) == "intercepted")
        #expect(ProbeStore.snapshot.originRequests == 0)
    }

    @Test
    func `explicit request headers can route two sessions`() async throws {
        ProbeStore.reset()
        ProbeStore.register("request-a", route: .replay("A"))
        ProbeStore.register("request-b", route: .replay("B"))
        let first = try instrumentedSession(token: nil)
        let second = try instrumentedSession(token: nil)
        defer {
            first.invalidateAndCancel()
            second.invalidateAndCancel()
        }
        var firstRequest = URLRequest(url: testURL)
        firstRequest.setValue("request-a", forHTTPHeaderField: routeHeader)
        var secondRequest = URLRequest(url: testURL)
        secondRequest.setValue("request-b", forHTTPHeaderField: routeHeader)

        #expect(try await body(from: first, request: firstRequest) == "A")
        #expect(try await body(from: second, request: secondRequest) == "B")
        #expect(ProbeStore.snapshot.interceptions == ["request-a": 1, "request-b": 1])
    }

    @Test
    func `request header overrides the configuration route`() async throws {
        ProbeStore.reset()
        ProbeStore.register("configuration", route: .replay("configuration"))
        ProbeStore.register("request", route: .replay("request"))
        let session = try instrumentedSession(token: "configuration")
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: testURL)
        request.setValue("request", forHTTPHeaderField: routeHeader)

        #expect(try await body(from: session, request: request) == "request")
        #expect(ProbeStore.snapshot.interceptions == ["request": 1])
    }

    @Test
    func `missing unknown and expired routes fail without origin access`() async throws {
        ProbeStore.reset()
        ProbeStore.register("expired", route: .replay("unreachable"))
        let missing = try instrumentedSession(token: nil, configuration: configurationWithOrigin())
        let unknown = try instrumentedSession(token: "unknown", configuration: configurationWithOrigin())
        let expired = try instrumentedSession(token: "expired", configuration: configurationWithOrigin())
        ProbeStore.expire("expired")
        defer {
            missing.invalidateAndCancel()
            unknown.invalidateAndCancel()
            expired.invalidateAndCancel()
        }

        for session in [missing, unknown, expired] {
            do {
                _ = try await body(from: session)
                Issue.record("An unrouteable request succeeded")
            } catch {}
        }
        #expect(ProbeStore.snapshot.rejectedRequests == 3)
        #expect(ProbeStore.snapshot.originRequests == 0)
        #expect(ProbeStore.snapshot.interceptedHeaders.count == 3)
    }

    @Test
    func `reserved header collision is rejected before session creation`() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [routeHeader.lowercased(): "caller"]
        #expect(throws: SetupError.reservedHeaderCollision) {
            try instrumentedSession(token: "probe", configuration: configuration)
        }
    }

    @Test
    func `cache is disabled and repeated GETs reach interception`() async throws {
        ProbeStore.reset()
        ProbeStore.register("cache", route: .replay("fresh"))
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 0, diskPath: nil)
        let session = try instrumentedSession(token: nil, configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: testURL)
        request.setValue("cache", forHTTPHeaderField: routeHeader)

        #expect(try await body(from: session, request: request) == "fresh")
        #expect(try await body(from: session, request: request) == "fresh")
        #expect(ProbeStore.snapshot.interceptions["cache"] == 2)
        #expect(session.configuration.urlCache == nil)
        #expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.urlCache != nil)
    }

    @Test
    func `URLProtocol property bypasses the interceptor when forwarding`() async {
        ProbeStore.reset()
        let request = NSMutableURLRequest(url: testURL)
        request.setValue("private-route", forHTTPHeaderField: routeHeader)
        request.setValue(nil, forHTTPHeaderField: routeHeader)
        URLProtocol.setProperty(true, forKey: forwardingProperty, in: request)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterceptingProtocol.self, OriginProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let forwardedBody = try? await body(from: session, request: request as URLRequest)
        withKnownLinuxIssue("FN-03: request bridging loses URLProtocol properties") {
            #expect(forwardedBody == "origin")
            #expect(ProbeStore.snapshot.rejectedRequests == 0)
            #expect(ProbeStore.snapshot.originRequests == 1)
        }
        #expect(ProbeStore.snapshot.interceptedForwardMarker == false)
        #expect(ProbeStore.snapshot.interceptions.isEmpty)
        #expect(ProbeStore.snapshot.originSawRouteHeader == false)
    }

    @Test
    func `forwarding without interceptor strips route and reaches origin`() async throws {
        ProbeStore.reset()
        let request = NSMutableURLRequest(url: testURL)
        request.setValue("private-route", forHTTPHeaderField: routeHeader)
        request.setValue(nil, forHTTPHeaderField: routeHeader)
        let session = URLSession(configuration: configurationWithOrigin())
        defer { session.invalidateAndCancel() }

        #expect(try await body(from: session, request: request as URLRequest) == "origin")
        #expect(ProbeStore.snapshot.originRequests == 1)
        #expect(ProbeStore.snapshot.originSawRouteHeader == false)
    }

    @Test
    func `uninstrumented session remains outside routing`() async throws {
        ProbeStore.reset()
        let session = URLSession(configuration: configurationWithOrigin())
        defer { session.invalidateAndCancel() }

        #expect(try await body(from: session) == "origin")
        #expect(ProbeStore.snapshot.interceptions.isEmpty)
        #expect(ProbeStore.snapshot.originRequests == 1)
    }

    private func configurationWithOrigin() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OriginProtocol.self]
        return configuration
    }
}
