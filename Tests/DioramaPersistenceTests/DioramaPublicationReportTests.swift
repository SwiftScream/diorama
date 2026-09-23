@testable import Diorama
import DioramaCore
@testable import DioramaPersistence
import DioramaRandom
import Foundation
import Synchronization
import Testing

struct DioramaPublicationReportTests {
    private struct SensitiveError: Error, CustomStringConvertible {
        let onDescription: @Sendable () -> Void

        var description: String {
            onDescription()
            return "SECRET-ERROR-PAYLOAD"
        }
    }

    @Test
    func `reports avoid inspecting arbitrary storage errors and in-memory content`() async throws {
        let descriptions = Mutex(0)
        let storage = PublicationStorage(beforeCommit: {
            throw SensitiveError(onDescription: { descriptions.withLock { $0 += 1 } })
        })
        let system = try StartupProbe().system(key: "record")
        let failure = try await Diorama(repository: randomRepository(storage: storage),
                                        scenarioID: "safe-error", mode: .record, systems: system)
            .execute { lease in
                try lease.append(capturing: { 42 }, preparation: ValuePreparation<UInt64>())
            }
        #expect(failure.report.disposition == .failed)
        #expect(failure.report.issues.map(\.cause) == [.unspecified])
        #expect(!failure.report.rendered().contains("SECRET-ERROR-PAYLOAD"))
        #expect(descriptions.withLock { $0 } == 0)

        let memory = try await Diorama(scenarioID: "memory", mode: .record, systems: system)
            .execute { lease in
                try lease.append(capturing: { 7 }, preparation: ValuePreparation<UInt64>())
            }
        #expect(memory.report.priorDocument == .notApplicable)
        #expect(memory.report.disposition == .notRequested)
        #expect(memory.report.candidate.isComplete)
        #expect(memory.report.issues.isEmpty)
    }

    @Test(arguments: ["create", "write", "commit", "cleanup"])
    func `file faults retain stage and prior document evidence without raw paths`(fault: String) async throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let prior = try persistedFixture("random-boundaries")
        try prior.write(to: fixture.location.fileURL)
        var operations = FileStorageOperations()
        switch fault {
        case "create": operations.createDirectory = { _ in throw storageFault(13) }
        case "write": operations.write = { bytes, url in
                try bytes.prefix(1).write(to: url)
                throw storageFault(5)
            }
        case "commit": operations.commit = { _, _ in throw storageFault(5) }
        default: operations.remove = { _ in throw storageFault(13) }
        }
        let storage = FileScenarioStorage(location: fixture.location, operations: operations)
        let repository = try JSONScenarioRepository(codec: PublicationFixtures.codec(), storage: storage)
        let system = try StartupProbe().system(key: "boundaries")
        let result = try await Diorama(repository: repository, scenarioID: "file-report", mode: .record,
                                       systems: system).execute { lease in
            try lease.append(capturing: { 42 }, preparation: ValuePreparation<UInt64>())
        }
        let candidate = try #require(result.definition)
        #expect(try PublicationFixtures.values("boundaries", in: candidate) == [42])
        let committed = fault == "cleanup"
        checkFileReport(result.report, fault: fault, rootPath: fixture.root.path)
        if committed {
            guard case let .published(receipt) = result.publication else {
                Issue.record("Expected completed commit"); return
            }
            #expect(receipt.cleanupFailure as? FileStorageError ==
                FileStorageError(operation: .cleanup, cause: .posix(13)))
            #expect(try PublicationFixtures.values("boundaries", in: repository.loadDefinition()) == [42])
        } else {
            guard case .failed(.storage) = result.publication else {
                Issue.record("Expected precommit failure"); return
            }
            #expect(try Data(contentsOf: fixture.location.fileURL) == prior)
        }
    }

    private func checkFileReport(_ report: DioramaReport, fault: String, rootPath: String) {
        let committed = fault == "cleanup"
        #expect(report.priorDocument == .present)
        #expect(report.candidate == PublicationCandidateSummary(
            isComplete: true, attachmentCount: 1, trackCount: 1,
            recordedCount: 1, incompleteCount: 0))
        #expect(report.diagnostics.isEmpty)
        #expect(report.disposition == (committed ? .published : .failed))
        #expect(report.preservation == (committed ? .committedByThisRun : .unchangedByThisRun))
        let operation: FileStorageOperation = fault == "commit" ? .commit : .stage
        let expectedStage: PublicationStage = committed ? .cleanup : .storage(operation)
        let expectedCode = fault == "create" || committed ? 13 : 5
        #expect(report.issues == [
            PublicationIssue(stage: expectedStage, cause: .file(.posix(expectedCode))),
        ])
        let disposition = committed ? "published" : "failed"
        let preservation = committed ? "committed-by-this-run" : "unchanged-by-this-run"
        let stage = committed ? "cleanup" : "storage-\(fault == "commit" ? "commit" : "stage")"
        let expected = [
            "Publication scenario=\"file-report\" prior=present "
                + "disposition=\(disposition) preservation=\(preservation)",
            "Candidate complete attachments=1 tracks=1 recorded=1 incomplete=0",
            "Publication issue stage=\(stage) scenario cause=posix-\(expectedCode)",
        ].joined(separator: "\n")
        let rendered = report.rendered()
        #expect(rendered.hasSuffix(expected))
        #expect(!rendered.contains(rootPath))
        #expect(!rendered.contains("secret-native-path-and-payload"))
    }

    @Test(arguments: ["preparation-validation", "conversion"])
    func `one failed recording stage refuses all writes and retains earlier facts`(fault: String) async throws {
        let prior = try persistedFixture("random-boundaries")
        let storage = PublicationStorage(document: prior)
        let probe = StartupProbe()
        let first = try probe.system(key: "first")
        let second = try probe.system(key: "boundaries")
        let result = try await Diorama(repository: randomRepository(storage: storage),
                                       scenarioID: "refusal", mode: .record,
                                       systems: first, second).execute { firstLease, secondLease in
            try firstLease.append(capturing: { 7 }, preparation: ValuePreparation<UInt64>())
            _ = firstLease.report(.system(DiagnosticLabel("earlier")))
            switch fault {
            case "preparation-validation":
                do {
                    try secondLease.append(capturing: { 42 }, preparation: ValuePreparation<UInt64>(
                        validate: { _ in throw PublicationFixtures.Failure.body }))
                } catch { /* Live work continues after failed recording preparation. */ }
            default:
                do {
                    try secondLease.append(capturing: { throw PublicationFixtures.Failure.body },
                                           preparation: ValuePreparation<UInt64>())
                } catch { /* Live work continues after failed conversion. */ }
            }
            return 42
        }
        #expect(result.body == 42)
        #expect(result.definition == nil)
        #expect(storage.writeCount == 0)
        #expect(storage.document == prior)
        #expect(result.report.disposition == .refusedUnhealthy)
        #expect(result.report.priorDocument == .present)
        #expect(result.report.preservation == .unchangedByThisRun)
        #expect(result.report.candidate.isComplete == false)
        #expect(result.report.candidate.attachmentCount == 2)
        #expect(result.report.diagnostics.first?.diagnostic.issue == .system(DiagnosticLabel("earlier")))
        #expect(result.report.issues.count == 1)
        let stage: PublicationStage = switch fault {
        case "preparation-validation": .preparation(.validation)
        default: .conversion
        }
        #expect(result.report.issues[0].stage == stage)
        #expect(result.report.issues[0].context.trackID == second.attachment.trackIDs[0])
        #expect(result.report.rendered().contains("system-issue \"earlier\""))
        #expect(!result.report.rendered().contains("secret-native-path-and-payload"))
    }

    @Test
    func `precommit and postcommit cleanup failures stay distinct`() async throws {
        let fixture = try FileStorageFixture()
        defer { try? fixture.remove() }
        let prior = try persistedFixture("random-boundaries")
        try prior.write(to: fixture.location.fileURL)
        var operations = FileStorageOperations()
        operations.commit = { _, _ in throw storageFault(5) }
        operations.remove = { _ in throw storageFault(13) }
        let storage = FileScenarioStorage(location: fixture.location, operations: operations)
        let system = try StartupProbe().system(key: "boundaries")
        let result = try await Diorama(repository: JSONScenarioRepository(
            codec: PublicationFixtures.codec(), storage: storage),
        scenarioID: "double-fault", mode: .record, systems: system).execute { lease in
            try lease.append(capturing: { 42 }, preparation: ValuePreparation<UInt64>())
        }
        #expect(result.report.disposition == .failed)
        #expect(result.report.preservation == .unchangedByThisRun)
        #expect(result.report.issues == [
            PublicationIssue(stage: .storage(.commit), cause: .file(.posix(5))),
            PublicationIssue(stage: .cleanup, cause: .file(.posix(13))),
        ])
        #expect(try Data(contentsOf: fixture.location.fileURL) == prior)
    }
}

private extension JSONScenarioRepository {
    func loadDefinition() throws -> ScenarioDefinition {
        guard case let .loaded(definition, _) = load() else {
            throw PublicationFixtures.Failure.storage
        }
        return definition
    }
}
