import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

extension D05ForwardingTests {
    @Test(.enabled(if: d05CanForwardDecisions, "FN-11/FN-15: custom redirects trap and challenge answers can escape"),
          arguments: d05LiveDecisionKinds, [false, true])
    func `live decision continues after horizon without execution routing`(kind: String, cancel: Bool) async throws {
        let released = try await liveDecision(kind, cancel: cancel)
        let allReleased = await d02Eventually { released.allSatisfy(\.isReleased) }
        print("D05 decision \(kind)/\(cancel): session release=\(released.map(\.isReleased))")
        try #require(allReleased)
    }

    private func liveDecision(_ kind: String, cancel: Bool) async throws -> [D05WeakObject<URLSession>] {
        let server = try D03HTTPServer()
        var scenario: D05Scenario? = D05Scenario()
        let weakScenario = D05WeakObject(scenario!)
        let observation = D05ObservationGate(scenario)
        scenario = nil
        let redirectChoice = kind == "redirectFollow" ? "follow" : "refuse"
        let observer = D05NativeObserver(holdDecision: true, redirectChoice: redirectChoice)
        let session = d05ForwardSession(observer, setup: D05ForwardSetup(observation: observation, customSource: false))
        defer { session.invalidateAndCancel(); d05ResetForwarding() }
        let task = session.dataTask(with: server.url())
        task.resume()
        try #require(await d02Eventually {
            server.poll { _ in initialReply(kind) }
            return observer.events.withLock { $0.pending != nil }
        })
        let firstTail = try #require(D05ForwardProtocol.latest.withLock { $0 })
        let firstPrivate = try #require(firstTail.weakSession)
        let frozen = d05LiveHorizon(session, observation: observation)
        #expect(frozen == [kind.hasPrefix("redirect") ? "redirect" : "challenge"])
        #expect(weakScenario.isReleased)
        #expect(server.requests.count == 1)
        #expect(observer.events.withLock { $0.completions } == 0)
        #expect(firstTail.cancelCalls == 0)
        #expect(D05ForwardProtocol.setup.withLock { $0 == nil })
        if cancel {
            task.cancel()
        } else {
            observer.answerPending()
        }
        try await finishDecision(session, observer: observer, server: server, cancel: cancel)
        let lastTail = try #require(D05ForwardProtocol.latest.withLock { $0 })
        try #require(await d02Eventually { firstTail.invalidated && lastTail.invalidated })
        let lastPrivate = try #require(lastTail.weakSession)
        #expect(observer.events.withLock { $0.completions } == 1)
        #expect(observer.events.withLock { $0.errorCode } == (cancel ? URLError.cancelled.rawValue : nil))
        #expect(server.requests.count == (cancel || kind == "redirectRefuse" ? 1 : 2))
        if !cancel {
            #expect(observer.events.withLock { $0.body } == Data((kind == "redirectRefuse" ? "refused" : "final").utf8))
        }
        #expect(observation.detach().isEmpty)
        #expect(observer.liveOperations.withLock { $0.isEmpty })
        #expect(D05ForwardProtocol.continuations.withLock { $0.isEmpty })
        #expect(server.sendsSucceeded)
        return [D05WeakObject(session), firstPrivate, lastPrivate]
    }

    private func finishDecision(_ session: URLSession, observer: D05NativeObserver,
                                server: D03HTTPServer, cancel: Bool) async throws
    {
        try #require(await d02Eventually {
            server.poll { _ in D03HTTPReply(body: "final") }
            // A later response-disposition callback is separate from the held
            // redirect/challenge. Let the native response finish normally.
            if !cancel {
                observer.answerPending()
            }
            return observer.events.withLock { $0.invalidated }
        })
        await d05QueueBarrier(session.delegateQueue)
        await observer.abortDecisions()
    }

    private func initialReply(_ kind: String) -> D03HTTPReply {
        if kind.hasPrefix("redirect") {
            return D03HTTPReply(status: 302, location: "/final", body: "refused")
        }
        let scheme = kind == "challengeBasic" ? "Basic" : "Digest"
        return D03HTTPReply(status: 401, body: "denied", headers: ["WWW-Authenticate": d04ChallengeHeader(scheme)])
    }
}

private let d05CanForwardDecisions: Bool = {
    #if canImport(FoundationNetworking)
        ProcessInfo.processInfo.environment["DIORAMA_VERIFY_FOUNDATION_FIXES"] == "1"
    #else
        true
    #endif
}()

private let d05LiveDecisionKinds: [String] = {
    #if canImport(FoundationNetworking)
        // Native Digest remains outside the approved Linux profile (FN-16).
        ["redirectFollow", "redirectRefuse", "challengeBasic"]
    #else
        ["redirectFollow", "redirectRefuse", "challengeBasic", "challengeDigest"]
    #endif
}()
