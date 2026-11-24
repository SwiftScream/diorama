import DioramaCore
import DioramaHTTP
import DioramaPersistence
import DioramaRandom
import DioramaURLSession
import Foundation
import HTTPTypes
import Testing

@Suite(.timeLimit(.minutes(1)))
struct URLSessionRecordingSchemaTests {
    let schema = URLSessionRecordingSchema.standard
    let key = AttachmentKey(rawValue: "service")
    let capabilities: Set<URLSessionReplayCapability> = [
        .requestMethod("GET"), .redirect(status: 302), .authentication(.digest, isProxy: false),
        .responseDecision, .responseBody, .segmentedBody, .trailers, .failure, .openHorizon,
    ]

    @Test
    func `registered schema round trips a mixed scenario with ordered retries overrides and empty tracks`() throws {
        let codec = try codec()
        let bytes = try fixture()
        let definition = try codec.decode(bytes)
        #expect(definition.attachments.map(\.id.key.rawValue) == ["random", "service", "idle"])
        let service = definition.attachments[1]
        let track = try schema.replayTrack(in: service, supporting: capabilities)
        #expect(track.records.map(\.identity.sequence) == [0, 1, 2])
        #expect(try schema.replayTrack(in: definition.attachments[2], supporting: []).records.isEmpty)
        let rebuilt = try schema.attachment(key: key, interactions: track.records.map(\.value))
        let roundTrip = try codec.encode(ScenarioDefinition(attachments: [
            definition.attachments[0], rebuilt, definition.attachments[2],
        ]))
        #expect(roundTrip.data == bytes)
        #expect(roundTrip.resources.isEmpty)
    }

    @Test
    func `every required behavior is checked even in later interactions and attempts`() throws {
        let service = try codec().decode(fixture()).attachments[1]
        for capability in capabilities {
            do {
                _ = try schema.replayTrack(in: service, supporting: capabilities.subtracting([capability]))
                Issue.record("Replay admitted an incomplete profile")
            } catch let URLSessionRecordingError.unsupported(location, rule) {
                #expect(location.record.trackID.attachmentID == service.id)
                if capability == .trailers {
                    #expect(location.record.sequence == 1)
                    #expect(location.attempt == 2)
                    #expect(location.fieldPath.map(\.text) == ["body.conclusion.completion.trailers"])
                    #expect(rule.text == "urlsession.requires-trailers")
                }
            }
        }
    }

    @Test
    func `the registered version and deep structural errors are diagnosed before admission`() throws {
        let codec = try codec()
        let input = try #require(try String(data: fixture(), encoding: .utf8))
        let badVersion = input.replacingOccurrences(
            of: #""schemaVersion" : 1,\#n      "type" : "diorama.urlsession""#,
            with: #""schemaVersion" : 2,\#n      "type" : "diorama.urlsession""#)
        #expect(throws: PersistenceDispatchError.unsupportedSchemaVersion(
            systemTypeID: schema.systemType.id, declared: 2, supported: [1]))
        {
            try codec.decode(Data(badVersion.utf8))
        }
        let badTag = input.replacingOccurrences(of: #""kind" : "allow""#, with: #""kind" : "private-value""#)
        do {
            _ = try codec.decode(Data(badTag.utf8))
            Issue.record("Unknown nested outcome accepted")
        } catch let PersistedScenarioCodingError.malformed(path) {
            #expect(path.contains("interactions") && path.contains("retry"))
            #expect(path.suffix(3) == ["disposition", "outcome", "kind"])
        }
    }

    @Test
    func `nested malformed scalar and body errors retain the schema field path`() throws {
        let source = try #require(try String(data: fixture(), encoding: .utf8))
        let cases = [
            (#""status" : 200"#, #""status" : 1000"#, ["head", "value", "status"]),
            (#""status" : 200"#, #""status" : 103"#, ["head", "value", "status"]),
            (#""kind" : "bytes""#, #""kind" : "secret""#, ["outcome", "body", "content", "kind"]),
            (#""version" : 1"#, #""version" : 5"#, ["result", "failure", "value", "version"]),
        ]
        let codec = try codec()
        for (original, edit, suffix) in cases {
            let data = Data(source.replacingOccurrences(of: original, with: edit).utf8)
            do {
                _ = try codec.decode(data)
                Issue.record("Malformed value accepted")
            } catch let PersistedScenarioCodingError.malformed(path) {
                #expect(path.contains("interactions"))
                #expect(Array(path.suffix(suffix.count)) == suffix)
            }
        }
    }

    @Test
    func `keyed policy admission validates without transforming authored credentials`() throws {
        let input = try #require(try String(data: fixture(), encoding: .utf8))
            .replacingOccurrences(of: #""user" : "redacted""#, with: #""user" : "fixture-user""#)
        let custom = try URLSessionRecordingSchema(preparations: [
            key: HTTPPreparation(authenticationUsername: .constant("fixture-user")),
        ])
        let allowed = try codec(custom).decode(Data(input.utf8))
        let records = try custom.replayTrack(in: allowed.attachments[1], supporting: capabilities).records
        #expect(try codec(custom).encode(allowed).data == Data(input.utf8))
        #expect(throws: URLSessionRecordingError.self) { try codec().decode(Data(input.utf8)) }
        #expect(throws: URLSessionRecordingError.self) { try codec().encode(allowed) }
        do {
            _ = try custom.attachment(key: AttachmentKey(rawValue: "another"), interactions: records.map(\.value))
            Issue.record("Default policy accepted a custom identity")
        } catch let URLSessionRecordingError.invalidValue(location) {
            #expect(location.record.sequence == 1 && location.attempt == 1)
            #expect(location.fieldPath.map(\.text) == ["authenticate.outcome.credential.user"])
        }
    }

    @Test(arguments: [
        NSLocalizedDescriptionKey,
        "_NSURLErrorFailingURLSessionTaskErrorKey",
        "_NSURLErrorRelatedURLSessionTaskErrorKey",
    ])
    func `recording admission rejects excluded native error metadata`(key: String) throws {
        let source = try #require(try String(data: fixture(), encoding: .utf8))
        let edited = source.replacingOccurrences(of: #""userInfo" : {"#,
                                                 with: #""userInfo" : {"\#(key)":{"type":"string","value":"marker"}"#)
        do {
            _ = try codec().decode(Data(edited.utf8))
            Issue.record("Excluded metadata entered the registered URLSession track")
        } catch let URLSessionRecordingError.invalidValue(location) {
            #expect(location.fieldPath.map(\.text) == ["result.failure", "userInfo"])
        }
    }

    @Test
    func `resources resolve at load and edited bytes keep their owned representation`() throws {
        let input = try #require(try String(data: fixture(), encoding: .utf8))
        let resource = input.replacingOccurrences(of: #""kind" : "bytes""#, with: #""kind" : "resource""#)
            .replacingOccurrences(of: #""text" : "€!""#, with: #""resource" : "payload.bin""#)
        let codec = try codec()
        let bytes = Data(resource.utf8)
        #expect(throws: ScenarioResourceError.unavailable) { try codec.decode(bytes) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = try ScenarioResourcePath("payload.bin")
        let location = try ScenarioFileLocation(rootDirectory: root, relativePath: "test.json")
        let storage = FileScenarioStorage(location: location)
        let editedBytes = Data([0, 1, 2, 3, 4, 5, 6])
        _ = try storage.publish(ScenarioDocument(data: bytes, resources: [path: editedBytes]))
        let repository = JSONScenarioRepository(codec: codec, storage: storage)
        guard case let .loaded(loaded, _) = repository.load() else {
            Issue.record("Expected registered resource resolution")
            return
        }
        try FileManager.default.removeItem(at: root)
        #expect(try schema.replayTrack(in: loaded.attachments[1], supporting: capabilities).records.count == 3)
        #expect(try codec.encode(loaded).resources == [path: editedBytes])
    }

    @Test
    func `system startup rejects a deep unsupported node before constructing any dependency`() async throws {
        let attachment = try codec().decode(fixture()).attachments[1]
        let definition = try ScenarioDefinition(attachments: [attachment])
        let bridge = SchemaTestSystem(supported: capabilities.subtracting([.trailers]), makeDependency: {
            Issue.record("Factory ran before validation completed")
        })
        let system = try ScenarioSystem(named: key.rawValue, definition: bridge)
        do {
            let run = try await ScenarioExecution.start(definition: definition, scenarioID: .init(rawValue: "replay"),
                                                        defaultMode: .replay, systems: [AnyScenarioSystem(system)])
            _ = await run.finish()
            Issue.record("Expected startup to reject trailers")
        } catch {
            let issue = DiagnosticIssue.system(DiagnosticLabel("urlsession.unsupported-replay-capability"))
            let fact = try #require(error.report.diagnostics.first { $0.diagnostic.issue == issue }?.diagnostic)
            #expect(fact.context.attachmentID == attachment.id)
            #expect(fact.context.recordIdentity?.sequence == 1)
            #expect(fact.fieldPath.map(\.text) == ["attempt", "2", "body.conclusion.completion.trailers"])
            #expect(fact.rule?.text == "urlsession.requires-trailers")
        }
        for mode: ScenarioMode in [.record, .passthrough, .replay] {
            let supported = mode == .replay ? capabilities : []
            let accepted = try ScenarioSystem(named: key.rawValue, definition: SchemaTestSystem(
                supported: supported, makeDependency: {}))
            let run = try await ScenarioExecution.start(definition: definition, scenarioID: .init(rawValue: "accepted"),
                                                        defaultMode: mode, systems: [AnyScenarioSystem(accepted)])
            _ = await run.finish()
        }
    }

    @Test
    func `redirect proposals require usable URLs in built and decoded recordings`() throws {
        let initial = try HTTPRequestMessage(head: HTTPRequest(
            method: .get, scheme: "https", authority: "example.invalid", path: "/start"))
        let delay = try HTTPDelay(milliseconds: .observed(0))
        let head = HTTPTimed(after: delay, value: HTTPResponseHead(head: HTTPResponse(status: .found)))
        let body = try HTTPBodyDelivery<URLSessionFailure>(
            content: .absent, conclusion: .returned(HTTPBodyCompletion(after: delay)))
        let codec = try codec()
        let targets: [RedirectTarget] = [
            .init(authority: nil, path: "/next", rejectedField: ["redirect.proposedRequest", "authority"]),
            .init(authority: "example.invalid", path: nil, rejectedField: ["redirect.proposedRequest", "path"]),
            .init(authority: ":443", path: "/next", rejectedField: ["redirect.proposedRequest"]),
            .init(authority: "example.invalid:8443", path: "/login%2Fnext?x=%2B", rejectedField: nil),
        ]
        for target in targets {
            let proposal = try HTTPRequestMessage(head: HTTPRequest(
                method: .get, scheme: "https", authority: target.authority, path: target.path))
            let phase = HTTPRedirectPhase(after: delay, proposedRequest: proposal, outcome: .refuse(.deliverBody(body)))
            let response = try HTTPResponseNode(head: head, next: .redirect(phase))
            let interaction = try HTTPInteraction(initialRequest: initial, result: .received(response))
            let json = try #require(String(data: JSONEncoder().encode(interaction), encoding: .utf8))
            let fixture = Data("""
            {"diorama":{"schemaVersion":1},"systems":[{
                "attachmentKey":"service","type":"diorama.urlsession","schemaVersion":1,
                "payload":{"interactions":[\(json)]}
            }]}
            """.utf8)
            let admit: [() throws -> ScenarioAttachment] = [
                { try schema.attachment(key: key, interactions: [interaction]) },
                { try #require(codec.decode(fixture).attachments.first) },
            ]
            for admission in admit {
                if let expectedField = target.rejectedField {
                    do {
                        _ = try admission()
                        Issue.record("Expected invalid redirect URL")
                    } catch let URLSessionRecordingError.invalidValue(location) {
                        #expect(location.record.trackID.attachmentID.key == key)
                        #expect(location.record.sequence == 0 && location.attempt == 0)
                        #expect(location.fieldPath.map(\.text) == expectedField)
                    }
                } else {
                    let track = try schema.replayTrack(in: admission(),
                                                       supporting: [.requestMethod("GET"), .redirect(status: 302)])
                    #expect(track.records.map(\.value) == [interaction])
                }
            }
        }
    }

    @Test(arguments: [
        (URLSessionReplayCapability.responseDecision, "urlsession.requires-response-decision"),
        (.dispositionCancellation, "urlsession.requires-disposition-cancellation"),
    ])
    func `startup identifies the missing capability at a shared decision path`(
        capability: URLSessionReplayCapability, rule: String) async throws
    {
        let request = try HTTPRequestMessage(head: HTTPRequest(
            method: .get, scheme: "https", authority: "example.invalid", path: "/"))
        let delay = try HTTPDelay(milliseconds: .observed(0))
        let failure = try HTTPTimed(after: delay, value: URLSessionFailure(domain: "canceled", code: 1))
        let response = try HTTPResponseNode(
            head: .init(after: delay, value: HTTPResponseHead(head: HTTPResponse(status: .ok))),
            next: .disposition(.init(after: delay, outcome: .cancel(failure))))
        let interaction = try HTTPInteraction(initialRequest: request, result: .received(response))
        let attachment = try schema.attachment(key: key, interactions: [interaction])
        let definition = try ScenarioDefinition(attachments: [attachment])
        let complete: Set<URLSessionReplayCapability> = [
            .requestMethod("GET"), .responseDecision, .dispositionCancellation, .failure,
        ]
        let bridge = SchemaTestSystem(supported: complete.subtracting([capability]), makeDependency: {
            Issue.record("Factory ran before validation completed")
        })
        let system = try ScenarioSystem(named: key.rawValue, definition: bridge)
        do {
            let run = try await ScenarioExecution.start(definition: definition, scenarioID: .init(rawValue: "decision"),
                                                        defaultMode: .replay, systems: [AnyScenarioSystem(system)])
            _ = await run.finish()
            Issue.record("Expected startup to reject the missing capability")
        } catch {
            let issue = DiagnosticIssue.system(DiagnosticLabel("urlsession.unsupported-replay-capability"))
            let fact = try #require(error.report.diagnostics.first { $0.diagnostic.issue == issue }?.diagnostic)
            #expect(fact.context.attachmentID == attachment.id)
            #expect(fact.context.recordIdentity?.sequence == 0)
            #expect(fact.fieldPath.map(\.text) == ["attempt", "0", "disposition.outcome"])
            #expect(fact.rule?.text == rule)
        }
    }

    private struct RedirectTarget {
        let authority: String?
        let path: String?
        let rejectedField: [String]?
    }

    private func fixture() throws -> Data {
        let resource = Bundle.module.url(forResource: "scenario", withExtension: "json", subdirectory: "Fixtures")
        let url = try #require(resource)
        return try Data(contentsOf: url)
    }

    private func codec(_ schema: URLSessionRecordingSchema = .standard) throws -> JSONScenarioCodec {
        let random = try DioramaRandomSystem.instance(named: "random")
        return try JSONScenarioCodec(registry: PersistentSystemRegistry([random.type, schema.systemType]))
    }
}

private struct SchemaTestSystem: SystemDefinition {
    let supported: Set<URLSessionReplayCapability>
    let makeDependency: @Sendable () -> Void
    let systemType = URLSessionRecordingSchema.standard.systemType
    let tracks = [URLSessionRecordingSchema.interactions.erased]

    func validate(in context: borrowing SystemValidationContext) throws {
        try URLSessionRecordingSchema.standard.validate(in: context, supporting: supported)
    }

    var record: SystemModeDefinition<Void, Void> {
        .init(makeDependency: makeDependency)
    }

    var replay: SystemModeDefinition<Void, Void> {
        record
    }

    var passthrough: SystemModeDefinition<Void, Void> {
        record
    }
}
