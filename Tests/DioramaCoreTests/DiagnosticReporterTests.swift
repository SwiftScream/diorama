@testable import DioramaCore
import Synchronization
import Testing

struct DiagnosticReporterTests {
    private final class LifetimeProbe: Sendable {
        let onRelease: @Sendable () -> Void
        init(onRelease: @escaping @Sendable () -> Void) {
            self.onRelease = onRelease
        }

        deinit { onRelease() }
    }

    @Test
    func `facts invalidate internal health immediately but expose only a completed report`() throws {
        let reporter = try makeReporter()
        #expect(reporter.report == nil)
        #expect(reporter.isRecordingHealthy)
        reporter.record(Diagnostic(issue: .system(DiagnosticLabel("observation"))))
        #expect(reporter.isRecordingHealthy)
        reporter.record(Diagnostic(issue: .conversionFailed, recordingImpact: .invalidatesCandidate))
        #expect(!reporter.isRecordingHealthy)
        #expect(reporter.report == nil)
        reporter.record(Diagnostic(issue: .system(DiagnosticLabel("later"))))
        #expect(!reporter.isRecordingHealthy)
        let report = reporter.freeze()
        #expect(reporter.report == report)
        #expect(report.diagnostics.map(\.sequence) == [0, 1, 2])
        #expect(report.diagnostics.map(\.diagnostic.issue) == [
            .system(DiagnosticLabel("observation")), .conversionFailed, .system(DiagnosticLabel("later")),
        ])
        #expect(report.recordingHealth.failures.map(\.sequence) == [1])
    }

    @Test
    func `concurrent retention keeps every fact without exposing a partial report`() async throws {
        let reporter = try makeReporter()
        let track = trackID("values")
        await withTaskGroup(of: Void.self) { group in
            for index in (0..<80).reversed() {
                group.addTask {
                    reporter.record(Diagnostic(
                        issue: .system(DiagnosticLabel("observation")),
                        context: .record(RecordIdentity(trackID: track, sequence: UInt64(index)))))
                    #expect(reporter.report == nil)
                    #expect(reporter.postFinishDiagnostics.isEmpty)
                }
            }
        }
        let entries = reporter.freeze().diagnostics
        #expect(entries.count == 80)
        #expect(Set(entries.map(\.sequence)) == Set(0..<UInt64(80)))
        #expect(entries.compactMap(\.diagnostic.context.recordIdentity?.sequence) == Array(0..<UInt64(80)))
    }

    @Test
    func `context ordering follows declarations and stable fallback identities`() throws {
        let first = attachmentID("z-declared")
        let second = attachmentID("a-declared")
        let firstTrack = TrackID(attachmentID: first, key: TrackKey(rawValue: "z-track"))
        let secondTrack = TrackID(attachmentID: first, key: TrackKey(rawValue: "a-track"))
        let attachment = try ScenarioAttachment(id: first)
            .adding(HeaderlessSequentialTrack<Int>(id: firstTrack))
            .adding(HeaderlessSequentialTrack<Int>(id: secondTrack))

        let definition = try ScenarioDefinition(attachments: [attachment, ScenarioAttachment(id: second)])
        let reporter = DiagnosticReporter(scenarioID: ScenarioID(rawValue: "ordered"), definition: definition)
        let contexts: [DiagnosticContext] = [
            .scenario,
            .attachment(first),
            .track(firstTrack),
            .record(RecordIdentity(trackID: firstTrack, sequence: 0)),
            .record(RecordIdentity(trackID: firstTrack, sequence: 1)),
            .track(secondTrack),
            .track(TrackID(attachmentID: first, key: TrackKey(rawValue: "unknown-a"))),
            .track(TrackID(attachmentID: first, key: TrackKey(rawValue: "unknown-z"))),
            .attachment(second),
            .attachment(attachmentID("unknown-a")),
            .attachment(attachmentID("unknown-z")),
            .attachment(AttachmentID(systemTypeID: SystemTypeID(rawValue: "z-system"), key: first.key)),
        ]
        for context in contexts.reversed() {
            reporter.record(Diagnostic(issue: .system(DiagnosticLabel("ordering")), context: context))
        }
        #expect(reporter.freeze().diagnostics.map(\.diagnostic.context) == contexts)
        #expect(contexts[3].attachmentID == first)
        #expect(contexts[3].trackID == firstTrack)
        #expect(contexts[0].attachmentID == nil)
        #expect(contexts[1].trackID == nil)
    }

    @Test
    func `post finish inspection is nonconsuming and never changes frozen facts or health`() async throws {
        let reporter = try makeReporter()
        reporter.record(Diagnostic(issue: .system(DiagnosticLabel("before"))))
        let frozen = reporter.freeze()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    reporter.record(Diagnostic(
                        issue: .system(DiagnosticLabel("after")), recordingImpact: .invalidatesCandidate))
                    #expect(reporter.report == frozen)
                    let late = reporter.postFinishDiagnostics
                    #expect(Set(late.map(\.sequence)).count == late.count)
                }
            }
        }
        #expect(reporter.freeze() == frozen)
        #expect(frozen.recordingHealth.isHealthy)
        #expect(reporter.isRecordingHealthy)
        let late = reporter.postFinishDiagnostics
        #expect(late.map(\.sequence) == Array(1...UInt64(40)))
        #expect(reporter.postFinishDiagnostics == late)
    }

    @Test
    func `reporter releases definition content and dies with its last owner`() throws {
        let releases = Mutex(0)
        var reporter: DiagnosticReporter? = try reporterWithContent(onRelease: { releases.withLock { $0 += 1 } })
        weak let weakReporter = reporter
        #expect(releases.withLock { $0 } == 1)
        let retained = try #require(reporter?.freeze())
        reporter?.record(Diagnostic(issue: .system(DiagnosticLabel("escaped-use"))))
        #expect(reporter?.postFinishDiagnostics.count == 1)
        reporter = nil
        #expect(weakReporter == nil)
        #expect(retained.diagnostics.isEmpty)
        #expect(retained.recordingHealth.isHealthy)
    }

    private func reporterWithContent(onRelease: @escaping @Sendable () -> Void) throws -> DiagnosticReporter {
        let track = trackID("content")
        let content = LifetimeProbe(onRelease: onRelease)
        let attachment = try ScenarioAttachment(id: track.attachmentID).adding(
            SequentialTrack(id: track, values: preparedValues([content])))
        return try DiagnosticReporter(
            scenarioID: ScenarioID(rawValue: "ownership"),
            definition: ScenarioDefinition(attachments: [attachment]))
    }

    private func makeReporter() throws -> DiagnosticReporter {
        try DiagnosticReporter(
            scenarioID: ScenarioID(rawValue: "diagnostics"),
            definition: ScenarioDefinition())
    }

    private func attachmentID(_ key: String) -> AttachmentID {
        AttachmentID(systemTypeID: SystemTypeID(rawValue: "example"), key: AttachmentKey(rawValue: key))
    }

    private func trackID(_ key: String) -> TrackID {
        TrackID(attachmentID: attachmentID("primary"), key: TrackKey(rawValue: key))
    }
}
