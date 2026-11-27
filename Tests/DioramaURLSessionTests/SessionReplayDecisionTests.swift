import Diorama
import DioramaCore
import DioramaHTTP
@testable import DioramaURLSession
import Foundation
import HTTPTypesFoundation
import Synchronization
import Testing

/// These tests share the process-wide native session registry with the bridge
/// teardown tests. Keep their scenarios inside the same serialized suite.
extension SessionBridgeTests {
    struct SessionReplayDecisionTests {
        private let url = URL(string: "https://example.invalid/fixture")!
    }
}

extension SessionBridgeTests.SessionReplayDecisionTests {
    enum Outcome: CaseIterable { case allow, cancel, open }
    enum Caller: CaseIterable { case delegate, completion, data, bytes }

    private final class Consumer: NSObject, URLSessionDataDelegate {
        typealias Reply = @Sendable (URLSession.ResponseDisposition) -> Void
        let reply = Mutex<Reply?>(nil)
        let chunks = Mutex<[Data]>([])
        let terminal = Mutex<[Int?]>([])
        let count = Mutex(0)
        let response = Mutex<HTTPURLResponse?>(nil)
        let times = Mutex<[ContinuousClock.Instant]>([])

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping Reply)
        {
            #expect(OperationQueue.current === session.delegateQueue)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(dataTask.response?.url == response.url)
            self.response.withLock { $0 = response as? HTTPURLResponse }
            reply.withLock { $0 = completionHandler }
            count.withLock { $0 += 1 }
        }

        func urlSession(_ session: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
            #expect(OperationQueue.current === session.delegateQueue)
            times.withLock { $0.append(.now) }
            chunks.withLock { $0.append(data) }
        }

        func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: any Error?) {
            #expect(OperationQueue.current === session.delegateQueue)
            times.withLock { $0.append(.now) }
            terminal.withLock { $0.append((error as NSError?)?.code) }
        }
    }

    private final class UnexpectedOrigin: URLProtocol {
        override static func canInit(with _: URLRequest) -> Bool {
            true
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            Issue.record("Replay reached the origin protocol")
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }

        override func stopLoading() {}
    }

    private func fixture(_ outcome: Outcome, consumer: Consumer?, decisionDelay: Int64 = 0, copies: Int = 1,
                         bodyOverride: HTTPBodyDelivery<URLSessionFailure>? = nil) throws
        -> (ScenarioDefinition, ScenarioSystem<URLSession>)
    {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnexpectedOrigin.self]
        let system = try DioramaURLSessionSystem.instance(named: "test", configuration: config, delegate: consumer)
        let request = try SessionMessage.request(URLRequest(url: url))
        let zero = try HTTPDelay(milliseconds: .override(0))
        let delay = try HTTPDelay(milliseconds: .override(50))
        let decision: HTTPResponseDispositionOutcome<URLSessionFailure>
        switch outcome {
        case .allow:
            let profile = try HTTPBodyProfile(segments: [
                .init(byteWeight: 3, after: delay), .init(byteWeight: 2, after: delay),
            ])
            let standard = try HTTPBodyDelivery<URLSessionFailure>(content: .bytes(Array("hello".utf8)),
                                                                   profile: profile,
                                                                   conclusion: .returned(.init(after: delay)))
            decision = .allow(bodyOverride ?? standard)
        case .cancel:
            decision = try .cancel(.init(after: zero, value: URLSessionFailure(domain: NSURLErrorDomain,
                                                                               code: URLError.cancelled.rawValue)))
        case .open: decision = .openAtRecordingHorizon
        }
        let fields: HTTPFields = [.contentType: "text/plain", .contentLength: "5"]
        let head = HTTPResponseHead(head: HTTPResponse(status: .ok, headerFields: fields))
        let after = try HTTPDelay(milliseconds: .override(decisionDelay))
        let node = try HTTPResponseNode(head: .init(after: zero, value: head),
                                        next: .disposition(.init(after: after, outcome: decision)))
        let recording = try HTTPInteraction(initialRequest: request, result: .received(node))
        let records = Array(repeating: recording, count: copies)
        let attachment = try URLSessionRecordingSchema.standard.attachment(key: system.attachment.id.key,
                                                                           interactions: records)
        return try (ScenarioDefinition(attachments: [attachment]), system)
    }

    private func wait(until condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    private func verify(_ outcome: Outcome, consumer: Consumer) async throws {
        try await wait { consumer.count.withLock { $0 == 1 } }
        #expect(consumer.chunks.withLock { $0.isEmpty })
        #expect(consumer.terminal.withLock { $0.isEmpty })
        if outcome != .open {
            let reply = try #require(consumer.reply.withLock { $0 })
            let answered = ContinuousClock.now
            reply(outcome == .cancel ? .cancel : .allow)
            try await wait { consumer.terminal.withLock { !$0.isEmpty } }
            let expectedChunks = outcome == .allow ? [Data("hel".utf8), Data("lo".utf8)] : []
            #expect(consumer.chunks.withLock { $0 } == expectedChunks)
            let expectedError = outcome == .cancel ? URLError.cancelled.rawValue : nil
            #expect(consumer.terminal.withLock { $0 } == [expectedError])
            if outcome == .allow {
                let times = consumer.times.withLock { $0 }
                #expect(times.count == 3)
                for (time, deadline) in zip(times, [50, 100, 150]) {
                    #expect(answered.duration(to: time) >= .milliseconds(deadline - 10))
                }
            }
        }
    }

    @Test(arguments: Outcome.allCases, Caller.allCases)
    func `missing and presented native decisions have different finalization facts`(outcome: Outcome, caller: Caller)
        async throws
    {
        let consumer = Consumer()
        let (definition, system) = try fixture(outcome, consumer: consumer)
        let execution = try await ScenarioExecution.start(definition: definition, scenarioID: .init(rawValue: "native"),
                                                          defaultMode: .replay, systems: [AnyScenarioSystem(system)])
        let session = try execution.dependency(system)
        var nativeTask: URLSessionDataTask?
        do {
            switch caller {
            case .delegate:
                let task = session.dataTask(with: url)
                nativeTask = task
                task.resume()
                try await verify(outcome, consumer: consumer)
            case .data: _ = try await session.data(from: url)
            case .bytes:
                let (stream, _) = try await session.bytes(from: url)
                for try await _ in stream {}
            case .completion:
                await withCheckedContinuation { done in
                    session.dataTask(with: url) { _, _, _ in done.resume() }.resume()
                }
            }
        } catch {
            _ = await execution.finish()
            throw error
        }
        let result = await execution.finish()
        let claimed = try #require(result.usage[0].tracks[0].claimedRecords.first)
        #expect(claimed.isConsumed == (caller == .delegate))
        let missing = DiagnosticIssue.system(DiagnosticLabel("urlsession.response-decision-not-presented"))
        let facts = result.report.diagnostics.map(\.diagnostic)
        let missingRecords = facts.filter { $0.issue == missing }.map(\.context.recordIdentity)
        #expect(missingRecords == (caller == .delegate ? [] : [claimed.identity]))
        #expect(result.evaluate(.allClaimedRecordsConsumed).isSatisfied == (caller == .delegate))
        #expect(consumer.count.withLock { $0 } == (caller == .delegate ? 1 : 0))
        if let nativeTask, outcome == .open {
            #expect(nativeTask.state == .completed)
            consumer.reply.withLock { $0 }?(.allow)
            #expect(execution.reporter.postFinishDiagnostics.isEmpty)
        }
    }

    @Test(arguments: [true, false])
    func `task delegate replacement is rejected and async delegates are observed`(replaces: Bool) async throws {
        let consumer = Consumer()
        let (definition, system) = try fixture(.cancel, consumer: nil)
        let execution = try await ScenarioExecution.start(definition: definition, scenarioID: .init(rawValue: "task"),
                                                          defaultMode: .replay, systems: [AnyScenarioSystem(system)])
        let session = try execution.dependency(system)
        do {
            if replaces {
                let task = session.dataTask(with: url)
                task.delegate = consumer
                task.resume()
                try await wait { consumer.terminal.withLock { !$0.isEmpty } }
                #expect(consumer.count.withLock { $0 } == 0)
                #expect(consumer.terminal.withLock { $0.first ?? nil } != nil)
            } else {
                let (body, response) = try await session.data(from: url, delegate: consumer)
                #expect(body.isEmpty && (response as? HTTPURLResponse)?.statusCode == 200)
            }
        } catch {
            _ = await execution.finish()
            throw error
        }
        let result = await execution.finish()
        #expect(!result.evaluate(replaces ? .allRecordsClaimed : .allClaimedRecordsConsumed).isSatisfied)
        let label: DiagnosticLabel = replaces ? .init("urlsession.unsupported-task")
            : .init("urlsession.response-decision-not-presented")
        #expect(result.report.diagnostics.map(\.diagnostic.issue).contains(.system(label)))
    }

    @Test
    func `overlapping identical requests verify their own callback`() async throws {
        let consumer = Consumer()
        let (definition, system) = try fixture(.open, consumer: consumer, copies: 2)
        let run = try await Diorama(definition: definition, scenarioID: "overlap", mode: .replay, systems: system)
            .execute { _, session in
                session.dataTask(with: url).resume()
                try await wait { consumer.count.withLock { $0 == 1 } }
                _ = try await session.data(from: url)
            }
        let facts = run.report.finalization
        let claims = facts.usage[0].tracks[0].claimedRecords
        #expect(claims.map(\.isConsumed) == [true, false])
        let missing = DiagnosticIssue.system(DiagnosticLabel("urlsession.response-decision-not-presented"))
        #expect(facts.report.diagnostics.map(\.diagnostic.issue) == [missing])
        #expect(facts.report.diagnostics.first?.diagnostic.context.recordIdentity?.sequence == 1)
    }

    @Test
    func `finish reports a missing question while native completion is still queued`() async throws {
        let consumer = Consumer()
        let (definition, system) = try fixture(.open, consumer: consumer, decisionDelay: 250)
        let execution = try await ScenarioExecution.start(definition: definition, scenarioID: .init(rawValue: "finish"),
                                                          defaultMode: .replay, systems: [AnyScenarioSystem(system)])
        let session = try execution.dependency(system)
        let owner = try #require(session.delegate as? SessionOwner)
        let task = session.dataTask(with: url) { _, _, _ in }
        task.resume()
        do {
            try await wait { owner.status(of: task) == .admitted }
            session.delegateQueue.isSuspended = true
            try await wait { task.response != nil }
            let finishing = Task { await execution.finish() }
            try await wait { owner.status(of: task) == nil }
            session.delegateQueue.isSuspended = false
            let result = await finishing.value
            let missing = DiagnosticIssue.system(DiagnosticLabel("urlsession.response-decision-not-presented"))
            #expect(result.report.diagnostics.map(\.diagnostic.issue) == [missing])
            #expect(!result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
            #expect(execution.reporter.postFinishDiagnostics.isEmpty)
        } catch {
            session.delegateQueue.isSuspended = false
            _ = await execution.finish()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func `an allowed body can remain open or deliver its recorded failure`(fails: Bool) async throws {
        let consumer = Consumer()
        let data = Data(repeating: 65, count: 2048)
        let error = try URLSessionFailure(domain: "test.transport", code: 73)
        let failure = try HTTPTimed(after: HTTPDelay(milliseconds: .override(20)), value: error)
        let body = HTTPBodyDelivery<URLSessionFailure>(content: .bytes(Array(data)),
                                                       conclusion: fails ? .failed(failure) : .openAtRecordingHorizon)
        let (definition, system) = try fixture(.allow, consumer: consumer, bodyOverride: body)
        let execution = try await ScenarioExecution.start(definition: definition, scenarioID: .init(rawValue: "body"),
                                                          defaultMode: .replay, systems: [AnyScenarioSystem(system)])
        let session = try execution.dependency(system)
        let task = session.dataTask(with: url)
        task.resume()
        do {
            try await wait { consumer.count.withLock { $0 == 1 } }
            consumer.reply.withLock { $0 }?(.allow)
            try await wait { consumer.chunks.withLock { $0 == [data] } }
            if fails {
                try await wait { consumer.terminal.withLock { $0 == [73] } }
                #expect((task.error as NSError?)?.domain == "test.transport")
            } else {
                #expect(consumer.terminal.withLock { $0.isEmpty })
            }
        } catch {
            _ = await execution.finish()
            throw error
        }
        let result = await execution.finish()
        #expect(result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
        #expect(result.report.diagnostics.isEmpty)
    }

    @Test
    func `explicit cancellation releases an unanswered native callback`() async throws {
        let consumer = Consumer()
        let (definition, system) = try fixture(.allow, consumer: consumer)
        let run = try await Diorama(definition: definition, scenarioID: "canceled", mode: .replay, systems: system)
            .execute { _, session in
                let task = session.dataTask(with: url)
                task.resume()
                try await wait { consumer.count.withLock { $0 == 1 } }
                task.cancel()
                try await wait { consumer.terminal.withLock { $0 == [URLError.cancelled.rawValue] } }
                consumer.reply.withLock { $0 }?(.allow)
            }
        #expect(run.report.finalization.report.diagnostics.isEmpty)
        #expect(!run.report.finalization.evaluated(.allClaimedRecordsConsumed).isSatisfied)
    }

    @Test
    func `a different delegate answer fails the task once`() async throws {
        let consumer = Consumer()
        let (definition, system) = try fixture(.cancel, consumer: consumer)
        let run = try await Diorama(definition: definition, scenarioID: "wrong", mode: .replay, systems: system)
            .execute { _, session in
                session.dataTask(with: url).resume()
                try await wait { consumer.count.withLock { $0 == 1 } }
                let reply = try #require(consumer.reply.withLock { $0 })
                reply(.allow)
                reply(.cancel)
                try await wait { consumer.terminal.withLock { !$0.isEmpty } }
            }
        #expect(consumer.terminal.withLock { $0 } == [(HTTPReplayError.incompatibleDecision as NSError).code])
        let result = run.report.finalization
        let issue = DiagnosticIssue.system(DiagnosticLabel("http.decision.mismatch"))
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [issue])
        #expect(!result.evaluated(.allClaimedRecordsConsumed).isSatisfied)
    }

    @Test
    func `a call with no response delegate rejects a decision before the response`() async throws {
        let (definition, system) = try fixture(.cancel, consumer: nil)
        let execution = try await ScenarioExecution.start(definition: definition, scenarioID: .init(rawValue: "early"),
                                                          defaultMode: .replay, systems: [AnyScenarioSystem(system)])
        let session = try execution.dependency(system)
        await #expect(throws: (any Error).self) { _ = try await session.data(from: url) }
        let result = await execution.finish()
        let issue = DiagnosticIssue.system(DiagnosticLabel("http.response-decision-unavailable"))
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [issue])
        #expect(!result.evaluate(.allClaimedRecordsConsumed).isSatisfied)
    }
}

extension SessionBridgeTests.SessionReplayDecisionTests {
    private func runDelegate(_ request: URLRequest, in session: URLSession, consumer: Consumer,
                             outcome: Outcome) async throws
    {
        session.dataTask(with: request).resume()
        try await wait { consumer.count.withLock { $0 == 1 } }
        #expect(consumer.chunks.withLock { $0.isEmpty })
        #expect(consumer.terminal.withLock { $0.isEmpty })
        if outcome != .open {
            consumer.reply.withLock { $0 }?(outcome == .allow ? .allow : .cancel)
            try await wait { consumer.terminal.withLock { !$0.isEmpty } }
        }
    }

    @Test(arguments: Outcome.allCases)
    func `a live text response decision replays through the same Foundation call`(outcome: Outcome) async throws {
        let origin = try AggregateOrigin()
        let url = try await origin.start()
        var post = URLRequest(url: url)
        post.httpMethod = "POST"
        post.httpBody = Data("hello".utf8)
        post.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        let request = post
        let live = Consumer()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let system = try DioramaURLSessionSystem.instance(named: "decisions", configuration: .ephemeral,
                                                          delegate: live, delegateQueue: queue)
        let capture = try await Diorama(scenarioID: "native", mode: .record, systems: system)
            .execute { _, session in try await runDelegate(request, in: session, consumer: live, outcome: outcome) }
        let definition = try #require(capture.definition)
        let track = try URLSessionRecordingSchema.standard.replayTrack(in: definition.attachments[0], supporting: [
            .requestMethod("POST"), .requestBody, .responseBody, .segmentedBody, .responseDecision,
            .dispositionCancellation, .failure, .openHorizon,
        ])
        guard case let .received(head) = try #require(track.records.first).value.result,
              case let .disposition(phase) = head.next
        else { Issue.record("Expected the observed delegate decision"); return }
        switch (outcome, phase.outcome) {
        case let (.allow, .allow(body)):
            #expect(body.content == .bytes(Array("hello".utf8)))
        case let (.cancel, .cancel(failure)):
            #expect(failure.value.code == URLError.cancelled.rawValue)
        case (.open, .openAtRecordingHorizon):
            live.reply.withLock { $0 }?(.allow)
            try await wait { live.terminal.withLock { !$0.isEmpty } }
            #expect(live.chunks.withLock { $0 } == [Data("hello".utf8)])
        default: Issue.record("Recorded the wrong decision")
        }
        let offline = Consumer()
        let replay = try DioramaURLSessionSystem.instance(named: "decisions", configuration: .ephemeral,
                                                          delegate: offline, delegateQueue: queue)
        let result = try await Diorama(definition: definition, scenarioID: "native", mode: .replay, systems: replay)
            .execute { _, session in try await runDelegate(request, in: session, consumer: offline, outcome: outcome) }
        #expect(result.report.finalization.evaluated(.allClaimedRecordsConsumed).isSatisfied)
        #expect(result.report.finalization.report.diagnostics.isEmpty)
        #expect(offline.chunks.withLock { $0 } == (outcome == .open ? [] : live.chunks.withLock { $0 }))
        let originalHead = try #require(live.response.withLock { $0 })
        let replayedHead = try #require(offline.response.withLock { $0 })
        #expect(replayedHead.url == originalHead.url)
        #expect(replayedHead.httpResponse == originalHead.httpResponse)
        if outcome != .open {
            #expect(offline.terminal.withLock { $0 } == live.terminal.withLock { $0 })
        }
        #expect(origin.observations.withLock { $0.connections == 1 && $0.requests.count == 1 })
    }

    @Test(arguments: [Caller.data, .bytes, .completion])
    func `aggregate recording with a response delegate has no disposition`(caller: Caller) async throws {
        let origin = try AggregateOrigin()
        let url = try await origin.start()
        let consumer = Consumer()
        let system = try DioramaURLSessionSystem.instance(named: "test", configuration: .ephemeral, delegate: consumer)
        let capture = try await Diorama(scenarioID: "ordinary", mode: .record, systems: system)
            .execute { _, session in
                switch caller {
                case .data: _ = try await session.data(from: url, delegate: consumer)
                case .bytes:
                    let (stream, _) = try await session.bytes(from: url, delegate: consumer)
                    for try await _ in stream {}
                case .completion:
                    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                        session.dataTask(with: url) { _, _, error in
                            if let error {
                                done.resume(throwing: error)
                            } else {
                                done.resume()
                            }
                        }.resume()
                    }
                case .delegate: Issue.record("Expected an aggregate call")
                }
            }
        let definition = try #require(capture.definition)
        let track = try URLSessionRecordingSchema.standard.replayTrack(
            in: definition.attachments[0], supporting: [.requestMethod("GET"), .responseBody])
        guard case let .received(head) = try #require(track.records.first).value.result,
              case let .deliverBody(body) = head.next, case .returned = body.conclusion
        else { Issue.record("Expected ordinary completed body delivery"); return }
        #expect(consumer.count.withLock { $0 } == 0)
    }
}

extension SessionBridgeTests.SessionReplayDecisionTests {
    @Test
    func `record and replay preserve segmented text after the delegate answers`() async throws {
        let origin = try AggregateOrigin(reply: .segmentedText)
        let request = try await URLRequest(url: origin.start())
        let live = Consumer()
        let system = try DioramaURLSessionSystem.instance(named: "test", configuration: .ephemeral, delegate: live)
        let expected = [Data(repeating: 65, count: 1024), Data("hello".utf8)]
        let capture = try await Diorama(scenarioID: "chunks", mode: .record, systems: system)
            .execute { _, session in
                session.dataTask(with: request).resume()
                try await wait { live.count.withLock { $0 == 1 } }
                live.reply.withLock { $0 }?(.allow)
                try await wait { live.chunks.withLock { $0 == [expected[0]] } }
                try await Task.sleep(for: .milliseconds(100))
                try origin.releaseTextTail()
                try await wait { live.terminal.withLock { !$0.isEmpty } }
            }
        #expect(live.chunks.withLock { $0 } == expected)
        let playback = Consumer()
        let replay = try DioramaURLSessionSystem.instance(named: "test", configuration: .ephemeral, delegate: playback)
        let result = try await Diorama(definition: #require(capture.definition), scenarioID: "chunks",
                                       mode: .replay, systems: replay)
            .execute { _, session in
                session.dataTask(with: request).resume()
                try await wait { playback.count.withLock { $0 == 1 } }
                try await Task.sleep(for: .milliseconds(75))
                #expect(playback.chunks.withLock { $0.isEmpty })
                playback.reply.withLock { $0 }?(.allow)
                try await wait { playback.terminal.withLock { !$0.isEmpty } }
            }
        #expect(playback.chunks.withLock { $0 } == expected)
        let intervals = [live, playback].compactMap { consumer in
            consumer.times.withLock { times in times.count == 3 ? times[0].duration(to: times[1]) : nil }
        }
        try #require(intervals.count == 2)
        #expect(intervals[1] >= intervals[0] - .milliseconds(20))
        #expect(result.report.finalization.evaluated(.allClaimedRecordsConsumed).isSatisfied)
        #expect(origin.observations.withLock { $0.connections == 1 })
    }

    @Test(arguments: [false, true])
    func `unsupported conversions fail recording and terminate the delegate task`(stream: Bool) async throws {
        let origin = try AggregateOrigin()
        let url = try await origin.start()
        let live = Consumer()
        let system = try DioramaURLSessionSystem.instance(named: "test", configuration: .ephemeral, delegate: live)
        let run = try await Diorama(scenarioID: "unsupported", mode: .record, systems: system)
            .execute { _, session in
                session.dataTask(with: url).resume()
                try await wait { live.count.withLock { $0 == 1 } }
                live.reply.withLock { $0 }?(stream ? .becomeStream : .becomeDownload)
                try await wait { live.terminal.withLock { !$0.isEmpty } }
            }
        #expect(run.definition == nil)
        #expect(live.terminal.withLock { $0 } == [(SessionBridgeError.unsupported as NSError).code])
        let facts = run.report.finalization.report.diagnostics.map(\.diagnostic)
        #expect(facts.filter { $0.issue == .system(DiagnosticLabel("urlsession.unsupported-disposition"))
                && $0.recordingImpact == .invalidatesCandidate
        }.count == 1)
    }

    @Test
    func `canceling a live task with a pending question freezes that question open`() async throws {
        let origin = try AggregateOrigin()
        let url = try await origin.start()
        let live = Consumer()
        let system = try DioramaURLSessionSystem.instance(named: "test", configuration: .ephemeral, delegate: live)
        let run = try await Diorama(scenarioID: "stop", mode: .record, systems: system)
            .execute { _, session in
                let task = session.dataTask(with: url)
                task.resume()
                try await wait { live.count.withLock { $0 == 1 } }
                task.cancel()
                try await wait { live.terminal.withLock { !$0.isEmpty } }
                live.reply.withLock { $0 }?(.allow)
            }
        let definition = try #require(run.definition)
        let track = try URLSessionRecordingSchema.standard.replayTrack(
            in: definition.attachments[0], supporting: [.requestMethod("GET"), .responseDecision, .openHorizon])
        guard case let .received(head) = try #require(track.records.first).value.result,
              case let .disposition(decision) = head.next, case .openAtRecordingHorizon = decision.outcome
        else { Issue.record("Expected the unanswered decision"); return }
        #expect(live.terminal.withLock { $0 } == [URLError.cancelled.rawValue])
    }
}
