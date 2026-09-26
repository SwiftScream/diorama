import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

extension D05ForwardingTests {
    @Test(arguments: ["completion", "async", "asyncDelegate"])
    func `aggregate live presentation completes after the horizon`(presentation: String) async throws {
        let released = try await aggregateLifetime(presentation)
        try #require(await d02Eventually { released.isReleased })
    }

    private func aggregateLifetime(_ presentation: String) async throws -> D05WeakObject<URLSession> {
        var scenario: D05Scenario? = D05Scenario()
        let weakScenario = D05WeakObject(scenario!)
        let observation = D05ObservationGate(scenario)
        scenario = nil
        let observer = D05NativeObserver()
        let session = d05ForwardSession(observer, setup: D05ForwardSetup(observation: observation))
        defer { session.invalidateAndCancel(); d05ResetForwarding() }
        let producer = Task {
            let url = URL(string: "http://d05.invalid/aggregate")!
            if presentation == "completion" {
                session.dataTask(with: url) { data, _, error in observer.complete(data: data, error: error) }.resume()
            } else {
                do {
                    let delegate = presentation == "asyncDelegate" ? observer : nil
                    let (data, _) = try await session.data(from: url, delegate: delegate)
                    observer.complete(data: data, error: nil)
                } catch { observer.complete(data: nil, error: error) }
            }
        }
        defer { producer.cancel() }
        try #require(await d02Eventually { D05LiveSourceProtocol.active.withLock { $0 != nil } })
        let source = try #require(D05LiveSourceProtocol.active.withLock { $0 })
        let tail = try #require(D05ForwardProtocol.latest.withLock { $0 })
        #expect(d05LiveHorizon(session, observation: observation).isEmpty)
        #expect(weakScenario.isReleased)
        #expect(observer.events.withLock { $0.completions } == 0)
        source.head()
        // Segmented aggregate correctness is tested separately by D02 (FN-01).
        source.bytes("complete")
        source.finish()
        try #require(await d02Eventually { observer.events.withLock { $0.invalidated } && tail.invalidated })
        await d05QueueBarrier(session.delegateQueue)
        await producer.value // Native invalidation does not await consumer Task scheduling.
        #expect(observer.events.withLock { $0.body } == Data("complete".utf8))
        #expect(observer.events.withLock { $0.errorCode } == nil)
        #expect(observer.events.withLock { $0.completions } == 1)
        #expect(tail.cancelCalls == 0)
        #expect(observation.detach().isEmpty)
        #expect(observer.liveOperations.withLock { $0.isEmpty })
        #expect(D05ForwardProtocol.continuations.withLock { $0.isEmpty })
        return D05WeakObject(session)
    }
}
