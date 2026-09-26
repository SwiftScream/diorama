import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization
import Testing

final class D05LifetimeObserver: NSObject, URLSessionDelegate {
    let invalidations = Mutex(0)

    func urlSession(_: URLSession, didBecomeInvalidWithError _: (any Error)?) {
        invalidations.withLock { $0 += 1 }
    }
}

private struct D05WeakSessionState: Sendable {
    weak var session: URLSession?
}

final class D05WeakSession: Sendable {
    private let state: Mutex<D05WeakSessionState>

    init(_ session: URLSession) {
        state = Mutex(D05WeakSessionState(session: session))
    }

    var isReleased: Bool {
        state.withLock { $0.session == nil }
    }

    func cleanUp() {
        state.withLock { $0.session }?.invalidateAndCancel()
    }
}

/// An inert interceptor needs no execution or global route to reject later use.
final class D05InertProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: NSError(domain: "D05ExpiredLease", code: 1))
    }

    override func stopLoading() {}
}

func d05InertSession(_ observer: D05LifetimeObserver) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [D05InertProtocol.self]
    configuration.urlCache = nil
    return URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
}

struct D05SessionLifetimeTests {
    @Test(arguments: [false, true])
    func `native session lifetime depends on invalidation`(invalidate: Bool) async throws {
        let observer = D05LifetimeObserver()
        let weakSession = await exerciseAndRelease(observer, invalidate: invalidate)
        defer { weakSession.cleanUp() }
        #if canImport(Darwin)
            if !invalidate {
                // This is an observed native lifetime boundary, not a passing
                // implementation of Diorama's escaped-session contract.
                #expect(!weakSession.isReleased)
                #expect(observer.invalidations.withLock { $0 } == 0)
                weakSession.cleanUp()
                try #require(await d02Eventually { observer.invalidations.withLock { $0 == 1 } })
            }
        #endif
        try #require(await d02Eventually { weakSession.isReleased })
        print("D05 session lifetime: invalidate=\(invalidate), released after required cleanup=true")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIORAMA_D05_INVALIDATED_SESSION"] == "1",
                   "Isolated process probe: Apple throws NSException; FoundationNetworking traps"))
    func `request on invalidated session reaches inert rejection`() async throws {
        let observer = D05LifetimeObserver()
        let session = d05InertSession(observer)
        session.finishTasksAndInvalidate()
        try #require(await d02Eventually { observer.invalidations.withLock { $0 == 1 } })
        do {
            _ = try await session.data(from: #require(URL(string: "http://127.0.0.1:1/expired")))
            Issue.record("Invalidated session unexpectedly succeeded")
        } catch {
            print("D05 invalidated session error: \((error as NSError).domain)/\((error as NSError).code)")
            #expect((error as NSError).domain == "D05ExpiredLease")
        }
    }

    private func exerciseAndRelease(_ observer: D05LifetimeObserver, invalidate: Bool) async -> D05WeakSession {
        let session = d05InertSession(observer)
        do {
            _ = try await session.data(from: URL(string: "http://127.0.0.1:1/expired")!)
            Issue.record("Inert session unexpectedly succeeded")
        } catch {
            #expect((error as NSError).domain == "D05ExpiredLease")
        }
        if invalidate {
            session.finishTasksAndInvalidate()
            #expect(await d02Eventually { observer.invalidations.withLock { $0 == 1 } })
        }
        return D05WeakSession(session)
    }
}
