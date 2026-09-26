import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

@Suite(.serialized)
struct D05OwnershipTests {
    @Test(arguments: ["expire", "cancel", "ambiguous", "missing"])
    func `asynchronous ownership rejects a stale or absent lease`(mode: String) async throws {
        let listener = try D02LoopbackListener()
        var scenario: D05Scenario? = D05Scenario()
        let weakScenario = try D05WeakObject(#require(scenario))
        let lease = D05RouteLease(scenario)
        scenario = nil
        let observer = D05NativeObserver()
        let session = d05RoutedSession(observer, lease: lease)
        let pause = D05LookupPause()
        D05Routes.pause.withLock { $0 = mode == "missing" ? nil : pause }
        defer {
            _ = lease.close()
            D05Routes.pause.withLock { $0 = nil }
            pause.release()
            session.invalidateAndCancel()
        }
        if mode == "missing" {
            _ = lease.close()
        }
        if mode == "ambiguous" {
            D05Routes.entries.withLock { $0.append(D05RouteEntry(session: session, lease: lease)) }
        }
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/ownership"))
        let task = session.dataTask(with: url) { data, _, error in observer.complete(data: data, error: error) }
        task.resume()
        if mode != "missing" {
            try #require(await d02Eventually { pause.result.withLock { $0 != nil } })
            #expect(lease.close().isEmpty)
            #expect(weakScenario.isReleased)
            if mode == "cancel" {
                task.cancel()
                try #require(await d02Eventually { observer.events.withLock { $0.completions == 1 } })
            }
            pause.release()
        }
        try #require(await d02Eventually { observer.events.withLock { $0.completions == 1 } })
        session.finishTasksAndInvalidate()
        try #require(await d02Eventually { observer.events.withLock { $0.invalidated } })
        await d05QueueBarrier(session.delegateQueue)
        #expect(observer.events.withLock { $0.body.isEmpty })
        #expect(observer.events.withLock { $0.errorCode } == (mode == "cancel" ? URLError.cancelled.rawValue : 1))
        #expect(D05Routes.entries.withLock { $0.isEmpty })
        #expect(weakScenario.isReleased)
        listener.poll()
        #expect(listener.connections == 0)
    }

    @Test
    func `repeated owned sessions release routes scenarios and native sessions`() async throws {
        for _ in 0..<30 {
            let released = try await oneLifetime()
            try #require(await d02Eventually { released.allReleased })
            #expect(D05Routes.entries.withLock { $0.isEmpty })
        }
    }

    private func oneLifetime() async throws -> D05ReleasedOwnership {
        let scenario = D05Scenario()
        let lease = D05RouteLease(scenario)
        let observer = D05NativeObserver()
        let session = d05RoutedSession(observer, lease: lease)
        defer { session.invalidateAndCancel(); _ = lease.close() }
        let (data, _) = try await session.data(from: #require(URL(string: "http://d05.invalid/ownership")))
        #expect(data == Data("routed".utf8))
        #expect(lease.close() == ["admit"])
        session.finishTasksAndInvalidate()
        try #require(await d02Eventually { observer.events.withLock { $0.invalidated } })
        await d05QueueBarrier(session.delegateQueue)
        return D05ReleasedOwnership(session: D05WeakObject(session), lease: D05WeakObject(lease),
                                    scenario: D05WeakObject(scenario))
    }
}

private struct D05ReleasedOwnership: Sendable {
    let session: D05WeakObject<URLSession>
    let lease: D05WeakObject<D05RouteLease>
    let scenario: D05WeakObject<D05Scenario>
    var allReleased: Bool {
        session.isReleased && lease.isReleased && scenario.isReleased
    }
}
