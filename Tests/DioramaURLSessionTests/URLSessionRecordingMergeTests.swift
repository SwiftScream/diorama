import Diorama
import DioramaCore
import DioramaHTTP
import DioramaPersistence
import DioramaURLSession
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct URLSessionRecordingMergeTests {
    @Test
    func `record finalization publishes the canonical candidate with FIFO timing overrides`() async throws {
        let file = try baselineFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try await run(file: file, track: URLSessionRecordingSchema.interactions)
        let expected = try fixture("candidate")
        #expect(result.report.publication.disposition == .published)
        #expect(try Data(contentsOf: file) == expected)
        let candidate = try #require(result.definition)
        #expect(try codec().encode(candidate).data == expected)
        let facts = result.report.finalization.report.diagnostics.map(\.diagnostic)
        #expect(facts.map(\.issue) == [
            .system(DiagnosticLabel("http.timing-override-retained")),
            .system(DiagnosticLabel("http.timing-override-retained")),
            .system(DiagnosticLabel("http.timing-override-obsolete")),
        ])
        #expect(facts.map { $0.context.recordIdentity?.sequence } == [0, 2, 3])
        #expect(facts.allSatisfy { $0.recordingImpact == .none && $0.fieldPath.map(\.text) == ["failure"] })
        #expect(!result.report.rendered().contains("/gone"))
    }

    @Test
    func `overlapping matches refuse publication and identify manual resolution without request values`() async throws {
        let file = try baselineFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = try Data(contentsOf: file)
        let matcher = HTTPRequestMatcher { lhs, rhs in
            lhs.path == rhs.path || lhs.path == "/new" || rhs.path == "/new"
        }
        let result = try await run(file: file, track: URLSessionRecordingSchema.interactions(matching: matcher))
        #expect(result.definition == nil)
        #expect(result.report.publication.disposition == .refusedUnhealthy)
        #expect(result.report.publication.preservation == .unchangedByThisRun)
        #expect(try Data(contentsOf: file) == original)
        let diagnostics = result.report.finalization.report.diagnostics
        #expect(diagnostics.allSatisfy { $0.diagnostic.recordingImpact == .invalidatesCandidate })
        let failures = result.report.finalization.report.recordingHealth.failures.map(\.diagnostic)
        let issue = DiagnosticIssue.system(DiagnosticLabel("http.correspondence-needs-resolution"))
        let fact = try #require(failures.first { $0.issue == issue })
        #expect(fact.context.recordIdentity?.sequence == 3)
        #expect(!result.report.rendered().contains("/new"))
    }

    @Test
    func `unhealthy capture skips correspondence and preserves the baseline file`() async throws {
        let file = try baselineFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let matcher = HTTPRequestMatcher { _, _ in
            Issue.record("Correspondence ran after capture failed")
            return true
        }
        let result = try await run(file: file, track: URLSessionRecordingSchema.interactions(matching: matcher),
                                   invalidateCapture: true)
        #expect(result.definition == nil)
        #expect(result.report.publication.disposition == .refusedUnhealthy)
        #expect(try Data(contentsOf: file) == fixture("baseline"))
    }

    private func run(file: URL, track: MergeTestSystem.Track, invalidateCapture: Bool = false) async throws
        -> DioramaResult<Void>
    {
        let system = try ScenarioSystem(named: "service", definition: MergeTestSystem(track: track))
        let definition = try codec().decode(fixture("fresh"))
        let values = try URLSessionRecordingSchema.standard.replayTrack(in: definition.attachments[0],
                                                                        supporting: [.failure, .requestMethod("GET")])
        return try await Diorama(file: file, scenarioID: "rerecord", mode: .record, systems: system)
            .execute { _, dependency in
                if invalidateCapture {
                    dependency.reporter.record(Diagnostic(issue: .conversionFailed,
                                                          recordingImpact: .invalidatesCandidate))
                }
                for record in values.records {
                    try dependency.state.withLock { state, operation in
                        _ = try operation.record(on: state, capturing: { record.value }, preparation: .init())
                    }
                }
            }
    }

    private func codec() throws -> JSONScenarioCodec {
        try JSONScenarioCodec(registry: PersistentSystemRegistry([URLSessionRecordingSchema.standard.systemType]))
    }

    private func baselineFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("scenario.json")
        try fixture("baseline").write(to: url)
        return url
    }

    private func fixture(_ name: String) throws -> Data {
        let resource = Bundle.module.url(
            forResource: "rerecord-\(name)", withExtension: "json", subdirectory: "Fixtures")
        return try Data(contentsOf: #require(resource))
    }
}

private struct MergeTestSystem: SystemDefinition {
    typealias Interaction = HTTPInteraction<URLSessionFailure>
    typealias Track = TrackDefinition<Interaction, Void>
    typealias State = HeaderlessSequentialTrackLease<Interaction>

    let track: Track
    let systemType = URLSessionRecordingSchema.standard.systemType
    var tracks: [AnyTrackDefinition] {
        [track.erased]
    }

    func validate(in context: borrowing SystemValidationContext) throws {
        try URLSessionRecordingSchema.standard.validate(in: context, supporting: [])
    }

    var record: SystemModeDefinition<State, SystemExecution<State>> {
        .init(makeState: { try $0.lease(for: track) }, makeDependency: { $0 })
    }

    var replay: SystemModeDefinition<State, SystemExecution<State>> {
        record
    }

    var passthrough: SystemModeDefinition<State, SystemExecution<State>> {
        record
    }
}
