import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

@Suite(.serialized)
struct D05ForwardingTests {
    @Test(arguments: ["beforeHead", "partialBody", "pendingResponse"], ["record", "passthrough"])
    func `live forwarding finishes without retaining the scenario`(phase: String, mode: String) async throws {
        let released = try await forwardingLifetime(phase: phase, mode: mode)
        try #require(await d02Eventually { released.0.isReleased && released.1.isReleased })
    }

    private func forwardingLifetime(phase: String, mode: String) async throws
        -> (D05WeakObject<URLSession>, D05WeakObject<D05ForwardTail>)
    {
        var scenario: D05Scenario? = D05Scenario()
        let weakScenario = D05WeakObject(scenario!)
        let observation = D05ObservationGate(mode == "record" ? scenario : nil)
        scenario = nil
        let observer = D05NativeObserver(holdDecision: phase == "pendingResponse")
        let session = d05ForwardSession(observer, setup: D05ForwardSetup(observation: observation))
        defer { observer.answerPending(); session.invalidateAndCancel(); d05ResetForwarding() }
        session.dataTask(with: URL(string: "http://d05.invalid/live")!).resume()
        try #require(await d02Eventually { D05LiveSourceProtocol.active.withLock { $0 != nil } })
        let source = try #require(D05LiveSourceProtocol.active.withLock { $0 })
        let tail = try #require(D05ForwardProtocol.latest.withLock { $0 })
        try await preparePhase(phase, source: source, observer: observer)
        let frozen = d05LiveHorizon(session, observation: observation)
        #expect(weakScenario.isReleased)
        #expect(observer.events.withLock { $0.completions } == 0)
        #expect(!tail.invalidated)
        #expect(tail.cancelCalls == 0)
        #expect(frozen == (mode == "passthrough" || phase == "beforeHead" ? [] :
                phase == "partialBody" ? ["head", "body"] : ["head"]))
        if phase == "beforeHead" {
            source.head()
        }
        if phase != "partialBody" {
            source.bytes("first-")
        }
        observer.answerPending()
        source.bytes("second")
        source.finish()
        try #require(await d02Eventually { observer.events.withLock { $0.invalidated } && tail.invalidated })
        await d05QueueBarrier(session.delegateQueue)
        await tail.drainExecutor()
        #expect(observer.events.withLock { $0.body } == Data("first-second".utf8))
        #expect(observer.events.withLock { $0.errorCode } == nil)
        #expect(observer.events.withLock { $0.completions } == 1)
        #expect(tail.cancelCalls == 0)
        #expect(observation.detach().isEmpty)
        #expect(observer.liveOperations.withLock { $0.isEmpty })
        #expect(D05ForwardProtocol.continuations.withLock { $0.isEmpty })
        let privateSession = try #require(tail.weakSession)
        try #require(await d02Eventually { privateSession.isReleased })
        return (D05WeakObject(session), D05WeakObject(tail))
    }

    private func preparePhase(_ phase: String, source: D02ControlledDelivery,
                              observer: D05NativeObserver) async throws
    {
        if phase != "beforeHead" {
            source.head()
            try #require(await d02Eventually { observer.events.withLock { $0.sequence.contains("head") } })
        }
        if phase == "partialBody" {
            source.bytes("first-")
            try #require(await d02Eventually { observer.events.withLock { !$0.body.isEmpty } })
        }
        if phase == "pendingResponse" {
            try #require(await d02Eventually { observer.events.withLock { $0.pending != nil } })
        }
    }

    @Test(arguments: ["beforeStart", "afterStart"])
    func `caller cancellation stops forwarding on its executor`(phase: String) async throws {
        let block = D05CallbackBlock()
        let observation = D05ObservationGate(nil)
        let observer = D05NativeObserver()
        let startBlock = phase == "beforeStart" ? block : nil
        let setup = D05ForwardSetup(observation: observation, startBlock: startBlock)
        let session = d05ForwardSession(observer, setup: setup)
        defer { block.release(); session.invalidateAndCancel(); d05ResetForwarding() }
        let task = try session.dataTask(with: #require(URL(string: "http://d05.invalid/cancel")))
        task.resume()
        try #require(await d02Eventually { D05ForwardProtocol.latest.withLock { $0 != nil } })
        let tail = try #require(D05ForwardProtocol.latest.withLock { $0 })
        if phase == "beforeStart" {
            try #require(await d02Eventually { block.entered.withLock { $0 } })
        } else {
            try #require(await d02Eventually { D05LiveSourceProtocol.active.withLock { $0 != nil } })
        }
        task.cancel()
        try #require(await d02Eventually { tail.stopped })
        block.release()
        await tail.drainExecutor()
        session.finishTasksAndInvalidate()
        try #require(await d02Eventually { observer.events.withLock { $0.invalidated } })
        if phase == "afterStart" {
            try #require(await d02Eventually { tail.invalidated })
        }
        #expect(observer.events.withLock { $0.errorCode } == URLError.cancelled.rawValue)
        #expect(observer.events.withLock { $0.completions } == 1)
        #expect(tail.cancelCalls == (phase == "beforeStart" ? 0 : 1))
        #expect(observer.liveOperations.withLock { $0.isEmpty })
        #expect(D05ForwardProtocol.continuations.withLock { $0.isEmpty })
        if phase == "beforeStart" {
            #expect(D05LiveSourceProtocol.active.withLock { $0 == nil })
        }
    }
}
