import Diorama
import DioramaCore
import DioramaHTTP
import DioramaPersistence
@testable import DioramaURLSession
import Foundation
import Synchronization
import Testing

private final class OriginProtocol: URLProtocol {
    static let requests = Mutex<[URLRequest]>([])
    static let held = Mutex<(@Sendable () -> Void)?>(nil)
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["X-Origin": "test"])
        else { return }
        if url.path == "/failure" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        if url.path == "/hold" {
            let tail = SessionDelivery(self)
            Self.held.withLock { $0 = {
                tail.response(response)
                tail.bytes(Data("tail".utf8))
                tail.finish()
            } }
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("origin".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SessionBridgeTests {
    private let url = URL(string: "https://example.invalid/")!

    private func setup(_ name: String = "service") throws -> ScenarioSystem<URLSession> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OriginProtocol.self]
        let system = try DioramaURLSessionSystem.instance(named: name, configuration: configuration)
        #expect(configuration.protocolClasses?.first == OriginProtocol.self)
        configuration.protocolClasses = []
        return system
    }

    private func baseline() throws -> ScenarioDefinition {
        let file = try #require(Bundle.module.url(forResource: "bodyless-get", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        return try JSONScenarioCodec(registry: .init([DioramaURLSessionSystem.type])).decode(Data(contentsOf: file))
    }

    @Test
    func `passthrough uses native session and accepts consumer invalidation`() async throws {
        let setup = try Diorama(scenarioID: "pass", mode: .passthrough, systems: setup())
        let run = try await setup.execute { _, session in
            #expect(session.configuration.protocolClasses?.first == OriginProtocol.self)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            let result = try await session.data(for: request)
            session.invalidateAndCancel()
            return result.0
        }
        #expect(run.body == Data("origin".utf8))
    }

    @Test
    func `record then replay`() async throws {
        OriginProtocol.requests.withLock { $0 = [] }
        let system = try setup()
        let recording = try await Diorama(scenarioID: "capture", mode: .record, systems: system)
            .execute { _, session in
                #expect(session.configuration.urlCache == nil)
                #expect(session.configuration.protocolClasses?.first == SessionProtocol.self)
                var request = URLRequest(url: url)
                request.setValue("client", forHTTPHeaderField: "X-Owner")
                return try await session.data(for: request).0
            }
        let definition = try #require(recording.definition)
        #expect(recording.body == Data("origin".utf8))
        let observed = OriginProtocol.requests.withLock { $0 }
        #expect(observed.count == 1)
        #expect(observed.first?.value(forHTTPHeaderField: "X-Owner") == "client")
        let track = try URLSessionRecordingSchema.standard.replayTrack(in: definition.attachments[0],
                                                                       supporting: [
                                                                           .requestMethod("GET"),
                                                                           .responseBody,
                                                                       ])
        let fields = try #require(track.records.first).value.initialRequest.head.headerFields
        #expect(!fields.contains { $0.name.canonicalName.hasPrefix("x-diorama") })
        let wireFields = observed.first?.allHTTPHeaderFields ?? [:]
        #expect(!wireFields.keys.contains { $0.lowercased().hasPrefix("x-diorama") })
        #expect(!recording.report.rendered().lowercased().contains("x-diorama"))
        #expect(track.records.count == 1)
        let replay = try await Diorama(
            definition: definition,
            scenarioID: "replay",
            mode: .replay,
            systems: system)
            .execute { _, session in
                var request = URLRequest(url: url)
                request.setValue("client", forHTTPHeaderField: "X-Owner")
                let (bytes, response) = try await session.data(for: request)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                return bytes
            }
        #expect(replay.body == recording.body)
        #expect(OriginProtocol.requests.withLock { $0.count } == 1)
    }

    @Test
    func `fixture replay and miss stay offline`() async throws {
        OriginProtocol.requests.withLock { $0 = [] }
        let setup = try Diorama(definition: baseline(), scenarioID: "replay", mode: .replay, systems: setup())
        _ = try await setup.execute { _, session in
            let result = try await session.data(from: url)
            #expect(result.0 == Data("ok".utf8))
            await #expect(throws: (any Error).self) {
                _ = try await session.data(from: url.appendingPathComponent("miss"))
            }
        }
        #expect(OriginProtocol.requests.withLock { $0.isEmpty })
    }

    @Test
    func `native failure preserves live error and refuses publication`() async throws {
        let run = try await Diorama(scenarioID: "failure", mode: .record, systems: setup())
            .execute { _, session in
                do {
                    _ = try await session.data(from: url.appendingPathComponent("failure"))
                    Issue.record("The origin failure was lost")
                } catch {
                    #expect((error as? URLError)?.code == .timedOut)
                }
            }
        #expect(run.definition == nil)
        let diagnostics = run.report.finalization.report.diagnostics.map(\.diagnostic)
        let expected = DiagnosticIssue.system(DiagnosticLabel("urlsession.unsupported-native-failure"))
        #expect(diagnostics.contains { $0.issue == expected && $0.context.recordIdentity?.sequence == 0
                && $0.recordingImpact == .invalidatesCandidate
        })
    }

    @Test
    func `unsupported requests fail before forwarding`() async throws {
        OriginProtocol.requests.withLock { $0 = [] }
        let run = try await Diorama(scenarioID: "unsupported", mode: .record, systems: setup())
            .execute { _, session in
                for method in ["POST", "GET"] {
                    var request = URLRequest(url: url)
                    request.httpMethod = method
                    request.httpBody = Data([42])
                    await #expect(throws: (any Error).self) { _ = try await session.data(for: request) }
                }
                let local = try #require(URL(string: "data:text/plain,unsupported"))
                await #expect(throws: (any Error).self) { _ = try await session.data(from: local) }
            }
        #expect(run.definition == nil)
        #expect(run.report.finalization.report.diagnostics.filter {
            $0.diagnostic.issue == .system(DiagnosticLabel("urlsession.unsupported-task"))
        }.count == 3)
        #expect(OriginProtocol.requests.withLock { $0.isEmpty })
    }

    @Test
    func `concurrent executions route identical tasks to their own session`() async throws {
        OriginProtocol.requests.withLock { $0 = [] }
        let replay = try Diorama(definition: baseline(), scenarioID: "read", mode: .replay, systems: setup())
        let record = try Diorama(scenarioID: "write", mode: .record, systems: setup())
        let result = try await record.execute { _, live in
            try await replay.execute { _, offline in
                async let recorded = live.data(from: url)
                async let replayed = offline.data(from: url)
                return try await [recorded.0, replayed.0]
            }.body
        }
        #expect(result.body == [Data("origin".utf8), Data("ok".utf8)])
        #expect(OriginProtocol.requests.withLock { $0.count } == 1)
    }

    @Test
    func `caller cancellation and finish drain open replay`() async throws {
        let setup = try Diorama(definition: baseline(), scenarioID: "cancel", mode: .replay, systems: setup())
        for cancel in [false, true] {
            let completed = Mutex<URLError.Code?>(nil)
            _ = try await setup.execute { _, session in
                let task = session.dataTask(with: url.appendingPathComponent("pending")) { _, _, error in
                    completed.withLock { $0 = (error as? URLError)?.code }
                }
                task.resume()
                let owner = try #require(session.delegate as? SessionOwner)
                try await waitUntil { owner.status(of: task) == .admitted }
                if cancel {
                    task.cancel()
                }
            }
            #expect(completed.withLock { $0 } == .cancelled)
            #expect(SessionRoutes.entries.withLock { $0.isEmpty })
        }
    }

    @Test
    func `finish joins executing native completion`() async throws {
        let setup = try Diorama(definition: baseline(), scenarioID: "drain", mode: .replay, systems: setup())
        let signals = AsyncStream<Void>.makeStream()
        let bodyDone = AsyncStream<Void>.makeStream()
        let unblock = DispatchSemaphore(value: 0)
        let callbackReturned = Mutex(false)
        let finishReturned = Mutex(false)
        let run = Task {
            _ = try await setup.execute { _, session in
                session.dataTask(with: url) { _, _, _ in
                    signals.continuation.finish()
                    _ = unblock.wait(timeout: .now() + 15)
                    callbackReturned.withLock { $0 = true }
                }.resume()
                for await _ in signals.stream {}
                bodyDone.continuation.finish()
            }
            finishReturned.withLock { $0 = true }
            #expect(callbackReturned.withLock { $0 })
        }
        defer { unblock.signal() }
        for await _ in bodyDone.stream {}
        try await waitUntil { SessionRoutes.entries.withLock { $0.isEmpty } }
        #expect(!finishReturned.withLock { $0 })
        unblock.signal()
        try await run.value
    }

    @Test
    func `ambiguous and missing owners fail closed`() async throws {
        OriginProtocol.requests.withLock { $0 = [] }
        let run = try await Diorama(scenarioID: "route", mode: .record, systems: setup())
            .execute { _, session in
                let owner = try #require(session.delegate as? SessionOwner)
                let entry = SessionRoutes.Entry(session: session, owner: owner)
                SessionRoutes.entries.withLock { $0.append(entry) }
                await #expect(throws: (any Error).self) { _ = try await session.data(from: url) }
                SessionRoutes.entries.withLock { $0.removeAll { $0.owner === owner } }
                await #expect(throws: (any Error).self) { _ = try await session.data(from: url) }
            }
        #expect(run.definition == nil)
        let facts = run.report.finalization.report.diagnostics.map(\.diagnostic)
        let issue = DiagnosticIssue.system(DiagnosticLabel("urlsession.invalid-ownership"))
        #expect(facts.filter { $0.issue == issue && $0.recordingImpact == .invalidatesCandidate }.count == 2)
        #expect(OriginProtocol.requests.withLock { $0.isEmpty })
    }

    @Test
    func `unsupported native families and delegate fail closed`() async throws {
        OriginProtocol.requests.withLock { $0 = [] }
        let result = try await Diorama(scenarioID: "families", mode: .record, systems: setup())
            .execute { _, session in
                await #expect(throws: (any Error).self) { _ = try await session.download(from: url) }
                await #expect(throws: (any Error).self) { _ = try await session.upload(
                    for: URLRequest(url: url),
                    from: Data()) }
                let socket = session.webSocketTask(with: URL(string: "ws://127.0.0.1:1/")!)
                socket.resume()
                await #expect(throws: (any Error).self) { _ = try await socket.receive() }
                let stream = session.streamTask(withHostName: "127.0.0.1", port: 1)
                stream.resume()
                let error = await withCheckedContinuation { continuation in
                    stream
                        .write(Data([1]), timeout: 5) { error in
                            continuation.resume(returning: error as? URLError)
                        }
                }
                #expect(error?.code == .cancelled)
                let supplied = SessionTestDelegate()
                await #expect(throws: (any Error).self) { _ = try await session.data(
                    from: url,
                    delegate: supplied) }
            }
        #expect(result.definition == nil)
        #expect(OriginProtocol.requests.withLock { $0.isEmpty })
    }

    @Test
    func `late resolved ownership cannot start canceled or expired work`() async throws {
        OriginProtocol.requests.withLock { $0 = [] }
        let result = try await Diorama(scenarioID: "lookup", mode: .record, systems: setup())
            .execute { _, session in
                let task = session.dataTask(with: url)
                // Hold the selected lease at the handoff between resolution and admission.
                let resolved = try #require(session.delegate as? SessionOwner)
                let canceled = SessionDelivery(SessionProtocol(task: task, cachedResponse: nil, client: nil))
                canceled.stop()
                resolved.start(canceled, request: URLRequest(url: url))
                // This request passes the same owner's admission queue after the canceled load.
                _ = try await session.data(from: url)
                return (
                    resolved,
                    SessionDelivery(SessionProtocol(task: task, cachedResponse: nil, client: nil)))
            }
        let (expired, late) = result.body
        expired.start(late, request: URLRequest(url: url))
        try await waitUntil {
            var closed = true
            late.whileOpen { closed = false }
            return closed
        }
        #expect(OriginProtocol.requests.withLock { $0.count } == 1)
        let track = try URLSessionRecordingSchema.standard.replayTrack(
            in: #require(result.definition).attachments[0], supporting: [.requestMethod("GET"), .responseBody])
        #expect(track.records.count == 1)
    }

    @Test
    func `later factory failure rolls back owned session`() async throws {
        let captured = CapturedRoute()
        let failing = try ScenarioSystem(named: "later", definition: FailingActivation(captured: captured))
        let setup = try Diorama(scenarioID: "rollback", mode: .record, systems: setup(), failing)
        await #expect(throws: (any Error).self) {
            _ = try await setup.execute { _, _, _ in Issue.record("Startup unexpectedly succeeded") }
        }
        let entry = try #require(captured.entry.withLock { $0 })
        #expect(SessionRoutes.entries.withLock { !$0.contains { $0.owner === entry.owner } })
        await entry.owner.drain(entry.session)
    }

    @Test
    func `instrumented setup refuses background and consumer callbacks`() async throws {
        let setups = try [
            DioramaURLSessionSystem.instance(
                named: "background",
                configuration: .background(withIdentifier: "i01")),
            DioramaURLSessionSystem.instance(named: "delegate", delegate: SessionTestDelegate()),
            DioramaURLSessionSystem.instance(named: "queue", delegateQueue: OperationQueue()),
        ]
        for system in setups {
            let scenario = try Diorama(scenarioID: "setup", mode: .record, systems: system)
            await #expect(throws: (any Error).self) {
                _ = try await scenario
                    .execute { _, _ in Issue.record("Unsupported configuration was accepted") }
            }
        }
        #expect(SessionRoutes.entries.withLock { $0.isEmpty })
    }

    private func waitUntil(_ check: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !check(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let observed = check()
        try #require(observed)
    }

    @Test
    func `finish detaches running record task`() async throws {
        OriginProtocol.held.withLock { $0 = nil }
        let run = try await Diorama(scenarioID: "tail", mode: .record, systems: setup())
            .execute { _, session in
                let tail = Task { try await session.data(from: url.appendingPathComponent("hold")).0 }
                let deadline = ContinuousClock.now + .seconds(10)
                while OriginProtocol.held.withLock({ $0 == nil }), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(2))
                }
                let ready = OriginProtocol.held.withLock { $0 != nil }
                try #require(ready)
                return tail
            }
        let release = OriginProtocol.held.withLock { value in
            defer { value = nil }
            return value
        }
        release?()
        #expect(try await run.body.value == Data("tail".utf8))
        let track = try URLSessionRecordingSchema.standard.replayTrack(
            in: #require(run.definition).attachments[0], supporting: [.requestMethod("GET"), .openHorizon])
        guard case .openAtRecordingHorizon = try #require(track.records.first).value.result else {
            Issue.record("An in-flight GET must freeze open"); return
        }
    }
}

private final class CapturedRoute: Sendable { let entry = Mutex<SessionRoutes.Entry?>(nil) }

private struct FailingActivation: SystemDefinition {
    let captured: CapturedRoute
    let systemType = ScenarioSystemType("i01.fail")

    var record: SystemModeDefinition<Void, Void> {
        .init(makeDependency: {
            captured.entry.withLock { $0 = SessionRoutes.entries.withLock { $0.last } }
            throw SessionBridgeError.configuration
        })
    }

    var replay: SystemModeDefinition<Void, Void> {
        record
    }

    var passthrough: SystemModeDefinition<Void, Void> {
        record
    }
}

private final class SessionTestDelegate: NSObject, URLSessionTaskDelegate {}
