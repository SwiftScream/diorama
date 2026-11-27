import Diorama
import DioramaCore
import DioramaHTTP
import DioramaPersistence
@testable import DioramaURLSession
import Foundation
import HTTPTypesFoundation
import Synchronization
import Testing

private final class OriginProtocol: URLProtocol {
    static let requests = Mutex<[URLRequest]>([])
    static let held = Mutex<[String: @Sendable () -> Void]>([:])
    static let stopped = Mutex<Set<String>>([])
    static let invalidDomain = String(repeating: "x", count: 257)
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        guard let url = request.url else { return }
        if let code = Int(url.lastPathComponent), url.path.hasPrefix("/failure/") {
            let error = NSError(domain: NSURLErrorDomain, code: code, userInfo: [
                NSURLErrorFailingURLErrorKey: url,
                "fixture": "supported-metadata",
                NSUnderlyingErrorKey: NSError(domain: "unrecorded-underlying-marker", code: 1),
                NSLocalizedDescriptionKey: "unrecorded-description-marker",
            ])
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if url.path == "/invalid-failure" {
            client?.urlProtocol(self, didFailWithError: NSError(domain: Self.invalidDomain, code: 42))
            return
        }
        let status = if url.path.hasPrefix("/status/") {
            Int(url.lastPathComponent) ?? 200
        } else {
            200
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["X-Origin": "test"])
        else { return }
        let name = url.lastPathComponent
        if name == "stream" {
            startStream(at: url)
            return
        }
        if name.hasPrefix("hold") {
            let tail = SessionDelivery(self)
            Self.held.withLock { $0[name] = {
                if name != "hold-failure" {
                    tail.response(response)
                    tail.bytes(Data(name.utf8))
                    tail.finish()
                } else {
                    tail.finish(URLError(.cannotConnectToHost))
                }
            } }
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("origin".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func startStream(at url: URL) {
        let tail = SessionDelivery(self)
        Self.held.withLock { $0["stream"] = {
            tail.bytes(Data("tail".utf8))
            tail.finish()
        } }
        let head = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/octet-stream"])!
        tail.response(head)
        tail.bytes(Data("prefix".utf8))
    }

    override func stopLoading() {
        if let name = request.url?.lastPathComponent, name.hasPrefix("hold") {
            Self.stopped.withLock { _ = $0.insert(name) }
        }
    }

    static func release(_ name: String) throws {
        let resume = try #require(held.withLock { $0.removeValue(forKey: name) })
        resume()
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SessionBridgeTests {
    enum TimeoutSource: CaseIterable {
        case request, sessionRequest, sessionResource
    }

    private let url = URL(string: "https://example.invalid/")!

    private func setup(_ name: String = "service") throws -> ScenarioSystem<URLSession> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OriginProtocol.self]
        let system = try DioramaURLSessionSystem.instance(named: name, configuration: configuration)
        #expect(configuration.protocolClasses?.first == OriginProtocol.self)
        configuration.protocolClasses = []
        return system
    }

    private func baseline(responseDelay: String = "10ms", completionDelay: String = "3ms") throws
        -> ScenarioDefinition
    {
        let file = try #require(Bundle.module.url(forResource: "bodyless-get", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        let fixture = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: #""10ms""#, with: #""\#(responseDelay)""#)
            .replacingOccurrences(of: #""3ms""#, with: #""\#(completionDelay)""#)
        return try JSONScenarioCodec(registry: .init([DioramaURLSessionSystem.type])).decode(Data(fixture.utf8))
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
                                                                           .responseBody, .segmentedBody,
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
    func `async bytes exposes a prefix before completion in record and replay`() async throws {
        OriginProtocol.requests.withLock { $0 = [] }
        let endpoint = url.appendingPathComponent("stream")
        let system = try setup()
        let scenario = try Diorama(scenarioID: "stream", mode: .record, systems: system)
        let recorded = try await scenario.execute { _, session in
            let consumed = Mutex(false)
            let reader = Task {
                let (bytes, head) = try await session.bytes(from: endpoint)
                #expect((head as? HTTPURLResponse)?.statusCode == 200)
                var result = [UInt8]()
                for try await byte in bytes {
                    result.append(byte)
                    if result == Array("prefix".utf8) {
                        consumed.withLock { $0 = true }
                    }
                }
                return result
            }
            defer { reader.cancel() }
            do {
                try await waitUntil { consumed.withLock { $0 } }
            } catch {
                try? OriginProtocol.release("stream")
                throw error
            }
            try await Task.sleep(for: .milliseconds(300))
            try OriginProtocol.release("stream")
            return try await reader.value
        }
        #expect(recorded.body == Array("prefixtail".utf8))
        let replay = try Diorama(definition: #require(recorded.definition), scenarioID: "stream",
                                 mode: .replay, systems: system)
        _ = try await replay.execute { _, session in
            let (bytes, head) = try await session.bytes(from: endpoint)
            #expect((head as? HTTPURLResponse)?.statusCode == 200)
            var result = [UInt8]()
            var prefixTime: ContinuousClock.Instant?
            for try await byte in bytes {
                result.append(byte)
                if result == Array("prefix".utf8) {
                    prefixTime = .now
                }
            }
            #expect(try #require(prefixTime).duration(to: .now) >= .milliseconds(150))
            #expect(result == recorded.body)
        }
        #expect(OriginProtocol.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: AggregateAPI.allCases)
    func `URL and request APIs share aggregate replay`(api: AggregateAPI) async throws {
        OriginProtocol.requests.withLock { $0 = [] }
        let system = try setup()
        let record = try Diorama(scenarioID: "aggregate", mode: .record, systems: system)
        let recorded = try await record.execute { _, session in
            try await api.fetch(URLRequest(url: url), in: session)
        }
        let replay = try Diorama(definition: #require(recorded.definition), scenarioID: "aggregate",
                                 mode: .replay, systems: system)
        let replayed = try await replay.execute { _, session in
            try await api.fetch(URLRequest(url: url), in: session)
        }
        #expect(recorded.body.data == Data("origin".utf8))
        #expect(recorded.body.status == 200)
        #expect(recorded.body.origin == "test")
        #expect(replayed.body == recorded.body)
        #expect(OriginProtocol.requests.withLock { $0.count } == 1)
    }

    @Test
    func `absent and empty request bodies select different records`() async throws {
        OriginProtocol.requests.withLock { $0 = [] }
        let system = try setup()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let absent = request
        request.httpBody = Data()
        let empty = request
        let record = try Diorama(scenarioID: "presence", mode: .record, systems: system)
        let captured = try await record.execute { _, session in
            for input in [absent, empty] {
                _ = try await session.data(for: input)
            }
        }
        let definition = try #require(captured.definition)
        let track = try URLSessionRecordingSchema.standard.replayTrack(
            in: definition.attachments[0],
            supporting: [.requestMethod("POST"), .requestBody, .responseBody, .segmentedBody])
        #expect(track.records.map(\.value.initialRequest.body) == [.absent, .bytes([])])
        let replay = try Diorama(definition: definition, scenarioID: "presence", mode: .replay, systems: system)
        _ = try await replay.execute { _, session in
            // Claim out of recording order, then check each claim has been consumed independently.
            for input in [empty, absent] {
                let result = try await session.data(for: input)
                #expect(result.0 == Data("origin".utf8))
                await #expect(throws: (any Error).self) { _ = try await session.data(for: input) }
            }
        }
        #expect(OriginProtocol.requests.withLock { $0.count } == 2)
    }

    @Test
    func `in-memory requests forward exact bytes and replay persisted content`() async throws {
        let origin = try AggregateOrigin()
        let endpoint = try await origin.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 5
        let cookie = try #require(HTTPCookie(properties: [
            .name: "session", .value: "live-cookie", .domain: "127.0.0.1", .path: "/",
        ]))
        let cookies = try #require(configuration.httpCookieStorage)
        cookies.setCookie(cookie)
        defer { cookies.deleteCookie(cookie) }
        let system = try DioramaURLSessionSystem.instance(named: "service", configuration: configuration)
        let json = Data(#" {"n":1.00,"n":2} "#.utf8)
        let binary = Data(0...255)
        let requests = [
            Self.patch(endpoint, body: json, type: "application/json"),
            Self.patch(endpoint, body: binary, type: "application/octet-stream"),
            Self.patch(endpoint, body: Data(binary.reversed()), type: "application/octet-stream"),
        ]

        let pass = try Diorama(scenarioID: "native", mode: .passthrough, systems: system)
        _ = try await pass.execute { _, session in
            let result = try await session.data(for: requests[0])
            #expect(result.0 == json)
        }
        let record = try Diorama(scenarioID: "echo", mode: .record, systems: system)
        let captured = try await record.execute { _, session in
            #expect(session.configuration.urlCredentialStorage == nil)
            #expect(session.configuration.httpShouldSetCookies)
            for input in requests {
                let result = try await session.data(for: input)
                #expect(result.0 == input.httpBody)
                #expect(result.1.expectedContentLength == Int64(result.0.count))
            }
        }
        let observed = origin.observations.withLock { $0 }
        Self.checkForwarding(observed, bodies: [json, json, binary, Data(binary.reversed())])

        let definition = try #require(captured.definition)
        let codec = try JSONScenarioCodec(registry: .init([DioramaURLSessionSystem.type]))
        let document = try codec.encode(definition)
        let text = try #require(String(bytes: document.data, encoding: .utf8))
        #expect(!text.contains("live-token"))
        #expect(!text.contains("live-cookie"))
        #expect(document.resources.count == 4)
        try Self.checkLengthsAndStorage(definition, json: json)

        try await Self.replayFromDisk(document, codec: codec, system: system, requests: requests)
        #expect(origin.observations.withLock { $0.connections } == observed.connections)
    }

    private static func checkForwarding(_ observed: AggregateOrigin.Observations, bodies: [Data]) {
        #expect(observed.connections == bodies.count)
        #expect(observed.requests.map(\.body) == bodies)
        for input in observed.requests {
            #expect(input.line == "PATCH /echo HTTP/1.1")
            #expect(input.fields["authorization"] == "Bearer live-token")
            #expect(input.fields["cookie"] == "session=live-cookie")
        }
    }

    private static func replayFromDisk(_ document: ScenarioDocument, codec: JSONScenarioCodec,
                                       system: ScenarioSystem<URLSession>, requests: [URLRequest]) async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = try ScenarioFileLocation(rootDirectory: root, relativePath: "echo.json")
        let storage = FileScenarioStorage(location: location)
        _ = try storage.publish(document)
        let repository = JSONScenarioRepository(codec: codec, storage: storage)
        guard case let .loaded(loaded, _) = repository.load() else {
            Issue.record("Could not load recorded resources"); return
        }
        let replay = try Diorama(definition: loaded, scenarioID: "echo", mode: .replay, systems: system)
        _ = try await replay.execute { _, session in
            for input in requests.reversed() {
                let result = try await AggregateAPI.requestCompletion.fetch(input, in: session)
                #expect(result.data == input.httpBody)
                #expect(result.length == Int64(result.data.count))
            }
            var miss = requests[1]
            let length = try #require(miss.httpBody?.count)
            miss.httpBody = Data(repeating: 0, count: length)
            let missing = miss
            await #expect(throws: (any Error).self) { _ = try await session.data(for: missing) }
        }
    }

    private static func patch(_ url: URL, body: Data, type: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.httpBody = body
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("Bearer live-token", forHTTPHeaderField: "Authorization")
        if type != "application/json" {
            request.setValue("identity", forHTTPHeaderField: "Content-Encoding")
        }
        return request
    }

    private static func checkLengthsAndStorage(_ definition: ScenarioDefinition, json: Data) throws {
        let track = try URLSessionRecordingSchema.standard.replayTrack(
            in: definition.attachments[0],
            supporting: [.requestMethod("PATCH"), .requestBody, .responseBody, .segmentedBody])
        try #require(track.records.count == 3)
        for (index, record) in track.records.enumerated() {
            let input = record.value.initialRequest
            guard case let .received(node) = record.value.result, case let .deliverBody(body) = node.next else {
                Issue.record("Expected an ordinary aggregate response"); continue
            }
            #expect(input.derivesContentLength == (index == 0))
            #expect(node.head.value.derivesContentLength == (index == 0))
            if index == 0 {
                #expect(input.body == .bytes(Array(json)))
                #expect(body.content == .bytes(Array(json)))
            } else {
                guard case .resource = input.body, case .resource = body.content else {
                    Issue.record("Expected resource-backed content"); continue
                }
            }
            #expect(body.profile?.segments.reduce(0) { $0 + $1.byteWeight } == Int64(index == 0 ? json.count : 256))
        }
    }

    @Test(arguments: [AggregateAPI.urlCompletion, .asyncURL])
    func `aggregate replay waits through the recorded conclusion`(api: AggregateAPI) async throws {
        let definition = try baseline(responseDelay: "130ms", completionDelay: "160ms")
        let scenario = try Diorama(definition: definition, scenarioID: "timing", mode: .replay, systems: setup())
        _ = try await scenario.execute { _, session in
            let start = ContinuousClock.now
            let result = try await api.fetch(URLRequest(url: url), in: session)
            let elapsed = start.duration(to: .now)
            #expect(result.data == Data("ok".utf8))
            #expect(elapsed >= .milliseconds(285))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIORAMA_I02_HTTPS"] == "1",
                   "Opt-in test against a publicly trusted HTTPS origin"))
    func `private transport uses native HTTPS trust`() async throws {
        let endpoint = try #require(URL(string: "https://example.com/"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let system = try DioramaURLSessionSystem.instance(named: "service", configuration: configuration)
        let scenario = try Diorama(scenarioID: "https", mode: .record, systems: system)
        let run = try await scenario.execute { _, session in
            let (bytes, response) = try await session.data(from: endpoint)
            #expect(!bytes.isEmpty)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            return bytes
        }
        let definition = try #require(run.definition)
        let replay = try Diorama(definition: definition, scenarioID: "https", mode: .replay, systems: system)
        let replayed = try await replay.execute { _, session in try await session.data(from: endpoint).0 }
        #expect(replayed.body == run.body)
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

    @Test(arguments: AggregateAPI.allCases)
    func `dependency errors round trip through aggregate APIs`(api: AggregateAPI) async throws {
        let codes = [
            URLError.timedOut.rawValue, URLError.cannotConnectToHost.rawValue, URLError.cancelled.rawValue, -12345,
        ]
        let requests = codes.map { URLRequest(url: url.appendingPathComponent("failure").appendingPathComponent(
            String($0))) }
        let system = try setup()
        OriginProtocol.requests.withLock { $0 = [] }
        let record = try Diorama(scenarioID: "failures", mode: .record, systems: system)
        let captured = try await record.execute { _, session in
            for (code, request) in zip(codes, requests) {
                let error = try await failure { _ = try await api.fetch(request, in: session) } as NSError
                #expect(error.domain == NSURLErrorDomain)
                #expect(error.code == code)
                #expect(error.userInfo[NSUnderlyingErrorKey] is NSError)
                #expect(error.userInfo["fixture"] as? String == "supported-metadata")
                #expect(error.localizedDescription == "unrecorded-description-marker")
            }
        }
        let definition = try #require(captured.definition)
        let codec = try JSONScenarioCodec(registry: .init([DioramaURLSessionSystem.type]))
        let document = try codec.encode(definition)
        try checkFailureRecording(definition, document: document,
                                  report: captured.report.finalization.report, codes: codes)
        #expect(!captured.report.rendered().contains("unrecorded-underlying-marker"))
        #expect(!captured.report.rendered().contains("unrecorded-description-marker"))

        let replay = try Diorama(definition: codec.decode(document.data), scenarioID: "failures",
                                 mode: .replay, systems: system)
        let replayed = try await replay.execute { _, session in
            for (code, request) in zip(codes, requests) {
                let error = try await failure { _ = try await api.fetch(request, in: session) }
                #expect(error is URLError)
                let native = error as NSError
                #expect(native.domain == NSURLErrorDomain)
                #expect(native.code == code)
                #expect(native.userInfo["fixture"] as? String == "supported-metadata")
                #expect(native.userInfo[NSURLErrorFailingURLErrorKey] as? URL == request.url)
                #expect(native.userInfo[NSUnderlyingErrorKey] == nil)
                #expect(native.localizedDescription != "unrecorded-description-marker")
            }
            let miss = try await failure { _ = try await session.data(from: url) } as NSError
            #expect(miss.domain != NSURLErrorDomain)
        }
        #expect(replayed.report.finalization.report.diagnostics.contains {
            $0.diagnostic.context.trackID != nil
        })
        #expect(OriginProtocol.requests.withLock { $0.count } == codes.count)
    }

    private func checkFailureRecording(_ definition: ScenarioDefinition, document: ScenarioDocument,
                                       report: DiagnosticReport, codes: [Int])
        throws
    {
        let track = try URLSessionRecordingSchema.standard.replayTrack(
            in: definition.attachments[0],
            supporting: [.requestMethod("GET"), .failure])
        let recordedCodes = try track.records.map { record in
            guard case let .failed(error) = record.value.result else {
                throw SessionBridgeError.conversion
            }
            return error.value.code
        }
        #expect(recordedCodes == codes)
        #expect(report.diagnostics.contains { entry in
            guard case let .nativeErrorMetadataOmitted(key, _) = entry.diagnostic.issue else { return false }
            return key == NSUnderlyingErrorKey && entry.diagnostic.recordingImpact == .none
        })
        let json = try #require(String(bytes: document.data, encoding: .utf8))
        #expect(!json.contains("unrecorded-underlying-marker"))
        #expect(!json.contains("unrecorded-description-marker"))
        #expect(!json.contains("_NSURLErrorFailingURLSessionTaskErrorKey"))
        #expect(!json.contains("_NSURLErrorRelatedURLSessionTaskErrorKey"))
    }

    @Test
    func `unrepresentable failure preserves live error and refuses publication`() async throws {
        let run = try await Diorama(scenarioID: "failure", mode: .record, systems: setup())
            .execute { _, session in
                let error = try await failure {
                    _ = try await session.data(from: url.appendingPathComponent("invalid-failure"))
                } as NSError
                #expect(error.domain == OriginProtocol.invalidDomain)
                #expect(error.code == 42)
            }
        #expect(run.definition == nil)
        let diagnostics = run.report.finalization.report.diagnostics.map(\.diagnostic)
        #expect(diagnostics.contains {
            $0.issue == .conversionFailed && $0.context.recordIdentity?.sequence == 0
                && $0.recordingImpact == .invalidatesCandidate && $0.fieldPath == [DiagnosticLabel("failure")]
        })
        #expect(!run.report.rendered().contains(OriginProtocol.invalidDomain))
    }

    @Test(arguments: TimeoutSource.allCases)
    func `a native timeout records an attempt failure`(source: TimeoutSource) async throws {
        let origin = try AggregateOrigin(reply: .silent)
        let url = try await origin.start()
        let configuration = URLSessionConfiguration.ephemeral
        let timeout: TimeInterval = 0.6
        configuration.timeoutIntervalForResource = source == .sessionResource ? timeout : 8
        if source == .sessionRequest {
            configuration.timeoutIntervalForRequest = timeout
        }
        let request = source == .request ? URLRequest(url: url, timeoutInterval: timeout) : URLRequest(url: url)
        let system = try DioramaURLSessionSystem.instance(named: "service", configuration: configuration)
        let record = try Diorama(scenarioID: "timeout", mode: .record, systems: system)
        let captured = try await record.execute { _, session in
            let error = try await failure {
                _ = try await session.data(for: request)
            }
            #expect((error as? URLError)?.code == .timedOut)
        }
        let definition = try #require(captured.definition)
        let track = try URLSessionRecordingSchema.standard.replayTrack(
            in: definition.attachments[0],
            supporting: [.requestMethod("GET"), .failure])
        guard case let .failed(recorded) = try #require(track.records.first).value.result else {
            Issue.record("Expected an attempt failure")
            return
        }
        #expect(recorded.after.milliseconds.value >= 300)
        #expect(recorded.after.milliseconds.value < 6000)
        #expect(recorded.value.code == URLError.timedOut.rawValue)
        let connections = origin.observations.withLock { $0.connections }
        #expect(connections > 0)
        let replayConfiguration = URLSessionConfiguration.ephemeral
        replayConfiguration.timeoutIntervalForRequest = 0.1
        replayConfiguration.timeoutIntervalForResource = 0.1
        let replaySystem = try DioramaURLSessionSystem.instance(named: "service", configuration: replayConfiguration)
        let replay = try Diorama(definition: definition, scenarioID: "timeout", mode: .replay, systems: replaySystem)
        let replayRequest = URLRequest(url: url, timeoutInterval: 0.1)
        _ = try await replay.execute { _, session in
            let started = ContinuousClock.now
            let error = try await failure { _ = try await session.data(for: replayRequest) }
            #expect((error as? URLError)?.code == .timedOut)
            #expect(started.duration(to: .now) >= .milliseconds(300))
        }
        #expect(origin.observations.withLock { $0.connections } == connections)
    }

    @Test
    func `truncated responses retain their prefix and failure delay`() async throws {
        let origin = try AggregateOrigin(reply: .truncated)
        let url = try await origin.start()
        let system = try DioramaURLSessionSystem.instance(named: "service", configuration: .ephemeral)
        let pass = try Diorama(scenarioID: "partial", mode: .passthrough, systems: system)
        let native = try await pass.execute { _, session in
            try await completionFailure(url, in: session)
        }
        let record = try Diorama(scenarioID: "partial", mode: .record, systems: system)
        let captured = try await record.execute { _, session in
            try await completionFailure(url, in: session)
        }
        let definition = try #require(captured.definition)
        let track = try URLSessionRecordingSchema.standard.replayTrack(
            in: definition.attachments[0],
            supporting: [.requestMethod("GET"), .responseBody, .segmentedBody, .failure])
        guard case let .received(response) = try #require(track.records.first).value.result,
              let body = response.body, case let .failed(error) = body.conclusion
        else { Issue.record("Expected a failure under the received response"); return }
        #expect(body.content == .bytes(Array("prefix".utf8)))
        #expect(response.head.value.head.headerFields[.contentLength] == "80")
        #expect(!response.head.value.derivesContentLength)
        #expect(error.value.domain == NSURLErrorDomain)
        #expect(error.value.code == native.body)
        #expect(error.after.milliseconds.value >= 90)
        #expect(captured.body == native.body)

        let connections = origin.observations.withLock { $0.connections }
        let replay = try Diorama(definition: definition, scenarioID: "partial", mode: .replay, systems: system)
        let replayed = try await replay.execute { _, session in
            let started = ContinuousClock.now
            let code = try await completionFailure(url, in: session)
            #expect(started.duration(to: .now) >= .milliseconds(90))
            return code
        }
        #expect(replayed.body == native.body)
        #expect(origin.observations.withLock { $0.connections } == connections)
    }

    @Test
    func `HTTP error statuses return ordinary responses`() async throws {
        let system = try setup()
        let urls = [404, 503].map { url.appendingPathComponent("status").appendingPathComponent(String($0)) }
        let record = try Diorama(scenarioID: "statuses", mode: .record, systems: system)
        let captured = try await record.execute { _, session in try await statuses(urls, in: session) }
        let replay = try Diorama(definition: #require(captured.definition), scenarioID: "statuses",
                                 mode: .replay, systems: system)
        let replayed = try await replay.execute { _, session in try await statuses(urls, in: session) }
        #expect(captured.body == [404, 503])
        #expect(replayed.body == captured.body)
    }

    @Test
    func `caller cancellation leaves a recording open`() async throws {
        OriginProtocol.stopped.withLock { $0.removeAll() }
        defer { OriginProtocol.held.withLock { $0.removeAll() } }
        let run = try await Diorama(scenarioID: "cancel", mode: .record, systems: setup())
            .execute { _, session in
                let task = Task { try await session.data(from: url.appendingPathComponent("hold-failure")) }
                try await waitUntil { OriginProtocol.held.withLock { $0["hold-failure"] != nil } }
                task.cancel()
                let error = try await failure { _ = try await task.value }
                #expect((error as? URLError)?.code == .cancelled)
                try await waitUntil { OriginProtocol.stopped.withLock { $0.contains("hold-failure") } }
            }
        let track = try URLSessionRecordingSchema.standard.replayTrack(
            in: #require(run.definition).attachments[0], supporting: [.requestMethod("GET"), .openHorizon])
        guard case .openAtRecordingHorizon = try #require(track.records.first).value.result else {
            Issue.record("Caller cancellation must leave the recording open")
            return
        }
    }

    @Test
    func `finish detaches a pending native failure`() async throws {
        defer { OriginProtocol.held.withLock { $0.removeAll() } }
        let run = try await Diorama(scenarioID: "late-failure", mode: .record, systems: setup())
            .execute { _, session in
                let task = Task { try await session.data(from: url.appendingPathComponent("hold-failure")) }
                try await waitUntil { OriginProtocol.held.withLock { $0["hold-failure"] != nil } }
                return task
            }
        try OriginProtocol.release("hold-failure")
        let error = try await failure { _ = try await run.body.value }
        #expect((error as? URLError)?.code == .cannotConnectToHost)
        let track = try URLSessionRecordingSchema.standard.replayTrack(
            in: #require(run.definition).attachments[0], supporting: [.requestMethod("GET"), .openHorizon])
        guard case .openAtRecordingHorizon = try #require(track.records.first).value.result else {
            Issue.record("Failure after finish must preserve the recorded horizon")
            return
        }
    }

    private func failure(_ perform: () async throws -> Void) async throws -> any Error {
        var received: any Error?
        do {
            try await perform()
        } catch {
            received = error
        }
        return try #require(received)
    }

    private struct TerminalCompletion: Sendable {
        let data: Data?
        let response: URLResponse?
        let error: any Error?
    }

    private func completionFailure(_ url: URL, in session: URLSession) async throws -> Int {
        let (stream, continuation) = AsyncStream<TerminalCompletion>.makeStream()
        let request = session.dataTask(with: url) { data, response, error in
            continuation.yield(.init(data: data, response: response, error: error))
            continuation.finish()
        }
        request.resume()
        var iterator = stream.makeAsyncIterator()
        let completion = try #require(await iterator.next())
        #expect(completion.data == nil)
        #expect((completion.response as? HTTPURLResponse)?.statusCode == 200)
        #expect(completion.response?.expectedContentLength == 80)
        let code = try #require(completion.error as? URLError).errorCode
        #expect((request.error as NSError?)?.code == code)
        return code
    }

    private func statuses(_ urls: [URL], in session: URLSession) async throws -> [Int] {
        var statuses: [Int] = []
        for url in urls {
            let (data, response) = try await session.data(from: url)
            #expect(data == Data("origin".utf8))
            let http = try #require(response as? HTTPURLResponse)
            statuses.append(http.statusCode)
        }
        return statuses
    }

    @Test
    func `unsupported requests fail before forwarding`() async throws {
        OriginProtocol.requests.withLock { $0 = [] }
        let run = try await Diorama(scenarioID: "unsupported", mode: .record, systems: setup())
            .execute { _, session in
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBodyStream = InputStream(data: Data([42]))
                await #expect(throws: (any Error).self) { _ = try await session.data(for: request) }
                await #expect(throws: (any Error).self) {
                    _ = try await session.data(for: URLRequest(url: url), delegate: SessionTestDelegate())
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
            in: #require(result.definition).attachments[0],
            supporting: [.requestMethod("GET"), .responseBody, .segmentedBody])
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
        let (entry, forwarding) = try #require(captured.sessions.withLock { $0 })
        #expect(SessionRoutes.entries.withLock { !$0.contains { $0.owner === entry.owner } })
        #expect(entry.owner.forwardingSession == nil)
        await entry.owner.drain(entry.session)
        try await waitUntil { forwarding.value == nil }
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
    func `overlapping requests share one private session and cancel independently`() async throws {
        OriginProtocol.stopped.withLock { $0.removeAll() }
        defer { OriginProtocol.held.withLock { $0.removeAll() } }
        let run = try await Diorama(scenarioID: "overlap", mode: .record, systems: setup())
            .execute { _, session in
                let forwarding = try #require((session.delegate as? SessionOwner)?.forwardingSession)
                let first = Task { try await session.data(from: url.appendingPathComponent("hold-first")).0 }
                let second = Task { try await session.data(from: url.appendingPathComponent("hold-second")).0 }
                let canceled = Task { try await session.data(from: url.appendingPathComponent("hold-canceled")).0 }
                defer {
                    first.cancel()
                    second.cancel()
                    canceled.cancel()
                }
                try await waitUntil { OriginProtocol.held.withLock { $0.count == 3 } }
                let privateTasks = await forwarding.allTasks
                #expect(privateTasks.count == 3)
                #expect(Set(privateTasks.compactMap { $0.originalRequest?.url?.lastPathComponent }) == [
                    "hold-first", "hold-second", "hold-canceled",
                ])
                canceled.cancel()
                let error = try await failure { _ = try await canceled.value }
                #expect((error as? URLError)?.code == .cancelled)
                try await waitUntil { OriginProtocol.stopped.withLock { $0.contains("hold-canceled") } }
                #expect(OriginProtocol.stopped.withLock { $0.isDisjoint(with: ["hold-first", "hold-second"]) })
                try OriginProtocol.release("hold-second")
                #expect(try await second.value == Data("hold-second".utf8))
                try OriginProtocol.release("hold-first")
                #expect(try await first.value == Data("hold-first".utf8))
            }
        let track = try URLSessionRecordingSchema.standard.replayTrack(
            in: #require(run.definition).attachments[0],
            supporting: [.requestMethod("GET"), .responseBody, .segmentedBody, .openHorizon])
        #expect(track.records.count == 3)
        let canceled = try #require(track.records.first { $0.value.initialRequest.head.path == "/hold-canceled" })
        guard case .openAtRecordingHorizon = canceled.value.result else {
            Issue.record("Caller cancellation must leave the recording open")
            return
        }
    }

    @Test
    func `attachments and successive executions have distinct forwarding sessions`() async throws {
        let scenario = try Diorama(
            scenarioID: "private-sessions", mode: .record, systems: setup("first"), setup("second"))
        let collect: @Sendable (URLSession, URLSession) throws -> [URLSession] = { first, second in
            try [first, second].map { try #require(($0.delegate as? SessionOwner)?.forwardingSession) }
        }
        let first = try await scenario.execute { _, first, second in try collect(first, second) }
        let second = try await scenario.execute { _, first, second in try collect(first, second) }
        #expect(Set((first.body + second.body).map { ObjectIdentifier($0) }).count == 4)
    }

    @Test
    func `finish detaches running record task and releases the forwarding session`() async throws {
        defer { OriginProtocol.held.withLock { $0.removeAll() } }
        let run = try await Diorama(scenarioID: "tail", mode: .record, systems: setup())
            .execute { _, session in
                let owner = try #require(session.delegate as? SessionOwner)
                let forwarding = try #require(owner.forwardingSession)
                let tail = Task { try await session.data(from: url.appendingPathComponent("hold")).0 }
                try await waitUntil { OriginProtocol.held.withLock { $0["hold"] != nil } }
                return (tail, owner, WeakSession(value: forwarding))
            }
        let (tail, owner, forwarding) = run.body
        #expect(owner.forwardingSession == nil)
        #expect(forwarding.value != nil)
        try OriginProtocol.release("hold")
        #expect(try await tail.value == Data("hold".utf8))
        try await waitUntil { forwarding.value == nil }
        let track = try URLSessionRecordingSchema.standard.replayTrack(
            in: #require(run.definition).attachments[0], supporting: [.requestMethod("GET"), .openHorizon])
        guard case .openAtRecordingHorizon = try #require(track.records.first).value.result else {
            Issue.record("An in-flight GET must freeze open"); return
        }
    }
}

private struct WeakSession: Sendable { weak var value: URLSession? }

private final class CapturedRoute: Sendable {
    let sessions = Mutex<(SessionRoutes.Entry, WeakSession)?>(nil)
}

private struct FailingActivation: SystemDefinition {
    let captured: CapturedRoute
    let systemType = ScenarioSystemType("i01.fail")

    var record: SystemModeDefinition<Void, Void> {
        .init(makeDependency: {
            let entry = try #require(SessionRoutes.entries.withLock { $0.last })
            let forwarding = try #require(entry.owner.forwardingSession)
            captured.sessions.withLock { $0 = (entry, WeakSession(value: forwarding)) }
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

struct AggregateResult: Equatable {
    let data: Data
    let status: Int
    let origin: String?
    let length: Int64
}

enum AggregateAPI: CaseIterable {
    case urlCompletion, requestCompletion, asyncURL, asyncRequest, httpTypes

    func fetch(_ request: URLRequest, in session: URLSession) async throws -> AggregateResult {
        let url = try #require(request.url)
        let native: (Data, URLResponse)
        switch self {
        case .urlCompletion, .requestCompletion:
            native = try await completion(request, url: url, session: session)
        case .asyncURL:
            native = try await session.data(from: url, delegate: nil)
        case .asyncRequest:
            native = try await session.data(for: request, delegate: nil)
        case .httpTypes:
            let (data, response) = try await session.data(for: #require(request.httpRequest), delegate: nil)
            return .init(data: data, status: response.status.code,
                         origin: response.headerFields[.init("X-Origin")!],
                         length: response.headerFields[.contentLength].flatMap(Int64.init) ?? -1)
        }
        let (data, response) = native
        let head = try #require(response as? HTTPURLResponse)
        return .init(data: data, status: head.statusCode, origin: head.value(forHTTPHeaderField: "X-Origin"),
                     length: head.expectedContentLength)
    }

    private func completion(_ request: URLRequest, url: URL, session: URLSession) async throws
        -> (Data, URLResponse)
    {
        try await withCheckedThrowingContinuation { continuation in
            let receive: @Sendable (Data?, URLResponse?, any Error?) -> Void = { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            let task = self == .urlCompletion
                ? session.dataTask(with: url, completionHandler: receive)
                : session.dataTask(with: request, completionHandler: receive)
            task.resume()
        }
    }
}

private final class SessionTestDelegate: NSObject, URLSessionTaskDelegate {}
