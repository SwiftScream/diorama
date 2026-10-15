import Diorama
import DioramaCore
import DioramaPersistence
import Foundation
import Testing

struct DioramaScopedReleasePublicationTests {
    private enum BodyFailure: Error, Equatable { case expected }

    @Test(arguments: [false, true])
    func `dependency release invalidation preserves the prior file on success and failure`(fails: Bool) async throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let system = try ScenarioSystem(named: "release", definition: PersistableReleaseDefinition())
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([system.type]))
        let original = try codec.encode(ScenarioDefinition(attachments: [system.attachment]))
        try original.write(to: fixture.location.fileURL)
        let setup = try Diorama(file: fixture.location.fileURL, scenarioID: "release-publication",
                                mode: .record, systems: system)
        do {
            let result = try await setup.execute { _, _ async throws(BodyFailure) -> Int in
                if fails {
                    throw .expected
                }
                return 42
            }
            #expect(!fails)
            #expect(result.body == 42)
            #expect(result.definition == nil)
            #expect(result.report == setup.report)
        } catch {
            #expect(fails)
            #expect(error as? BodyFailure == .expected)
        }
        let report = try #require(setup.report)
        #expect(report.publication.disposition == .refusedUnhealthy)
        #expect(report.publication.preservation == .unchangedByThisRun)
        #expect(!report.publication.candidate.isComplete)
        #expect(report.finalization.report.diagnostics.map(\.diagnostic.issue) == [
            .system(DiagnosticLabel("dependency-release")),
        ])
        #expect(try fixture.storage.load() == original)
        #expect(try fixture.entries() == ["scenario.json"])
    }
}

private struct PersistableReleaseDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.persistable-release", persistence: PersistentSystemRegistration(
        currentSchemaVersion: 1, payloadType: Int.self, encode: { _ in 0 }, decode: { _, key in
            ScenarioAttachment(id: AttachmentID(systemTypeID: SystemTypeID(rawValue: "consumer.persistable-release"),
                                                key: key))
        }))

    func makeRecordState(in _: borrowing SystemStateContext) {}
    func makeReplayState(in _: borrowing SystemStateContext) {}

    func makeRecordDependency(using execution: SystemExecution<Void>) -> PublicationReleaseDependency {
        PublicationReleaseDependency(reporter: execution.reporter)
    }

    func makeReplayDependency(using execution: SystemExecution<Void>) -> PublicationReleaseDependency {
        makeRecordDependency(using: execution)
    }

    func makePassthroughDependency(using execution: SystemExecution<Void>) -> PublicationReleaseDependency {
        makeRecordDependency(using: execution)
    }
}

private final class PublicationReleaseDependency: Sendable {
    private let reporter: DiagnosticReporter

    init(reporter: DiagnosticReporter) {
        self.reporter = reporter
    }

    deinit {
        reporter.record(Diagnostic(issue: .system(DiagnosticLabel("dependency-release")),
                                   recordingImpact: .invalidatesCandidate))
    }
}
