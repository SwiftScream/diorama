@testable import DioramaCore
import Dispatch
import Synchronization
import Testing

struct DiagnosticReporterTests {
    private struct SinkError: Error, CustomStringConvertible {
        let onDescription: @Sendable () -> Void
        var description: String {
            onDescription()
            return "SECRET-SINK-ERROR"
        }
    }

    private final class LifetimeProbe: Sendable {
        let onRelease: @Sendable () -> Void
        init(onRelease: @escaping @Sendable () -> Void) {
            self.onRelease = onRelease
        }

        deinit { onRelease() }
    }

    @Test
    func `retains facts and health before reentrant sink notification`() throws {
        let reference = Mutex<DiagnosticReporter?>(nil)
        defer { reference.withLock { $0 = nil } }
        let sink = DiagnosticSink { entry in
            let reporter = try #require(reference.withLock { $0 })
            #expect(reporter.report.diagnostics.contains(entry))
            #expect(!reporter.report.recordingHealth.isHealthy)
            if entry.diagnostic.issue == .system(DiagnosticLabel("outer")) {
                reporter.record(Diagnostic(issue: .system(DiagnosticLabel("inner"))))
            }
        }
        let reporter = try makeReporter(sink: sink)
        reference.withLock { $0 = reporter }
        reporter.record(Diagnostic(
            issue: .system(DiagnosticLabel("outer")),
            recordingImpact: .invalidatesCandidate))

        #expect(reporter.report.diagnostics.map(\.sequence) == [0, 1])
        #expect(reporter.report.diagnostics.map(\.diagnostic.issue) == [
            .system(DiagnosticLabel("outer")), .system(DiagnosticLabel("inner")),
        ])
        #expect(reporter.report.recordingHealth.failures.map(\.sequence) == [0])
    }

    @Test
    func `throwing sink preserves original facts without rendering or recursion`() throws {
        let calls = Mutex(0)
        let inspections = Mutex(0)
        let reporter = try makeReporter(sink: DiagnosticSink { _ in
            calls.withLock { $0 += 1 }
            throw SinkError(onDescription: { inspections.withLock { $0 += 1 } })
        })
        reporter.record(Diagnostic(issue: .system(DiagnosticLabel("observation"))))

        let report = reporter.report
        #expect(report.diagnostics.map(\.diagnostic.issue) == [
            .system(DiagnosticLabel("observation")), .sinkFailed,
        ])
        #expect(report.recordingHealth.isHealthy)
        #expect(calls.withLock { $0 } == 1)
        #expect(inspections.withLock { $0 } == 0)
        #expect(!String(reflecting: report).contains("SECRET-SINK-ERROR"))
    }

    @Test(arguments: [false, true])
    func `concurrent retention and inspection keep every fact exactly once`(hasSink: Bool) async throws {
        let calls = Mutex<[UInt64]>([])
        let reference = Mutex<DiagnosticReporter?>(nil)
        defer { reference.withLock { $0 = nil } }
        let sink = DiagnosticSink { entry in
            let reporter = try #require(reference.withLock { $0 })
            #expect(reporter.report.diagnostics.contains(entry))
            calls.withLock { $0.append(entry.sequence) }
        }
        let reporter = try makeReporter(sink: hasSink ? sink : nil)
        reference.withLock { $0 = reporter }
        let track = trackID("values")

        await withTaskGroup(of: Void.self) { group in
            for index in (0..<80).reversed() {
                group.addTask {
                    reporter.record(Diagnostic(
                        issue: .system(DiagnosticLabel("observation")),
                        context: .record(RecordIdentity(trackID: track, sequence: UInt64(index)))))
                    let snapshot = reporter.report
                    #expect(Set(snapshot.diagnostics.map(\.sequence)).count == snapshot.diagnostics.count)
                    #expect(reporter.postFinishDiagnostics.isEmpty)
                }
            }
        }
        let entries = reporter.report.diagnostics
        #expect(entries.count == 80)
        #expect(Set(entries.map(\.sequence)) == Set(0..<UInt64(80)))
        #expect(entries.compactMap(\.diagnostic.context.recordIdentity?.sequence) == Array(0..<UInt64(80)))
        #expect(calls.withLock { $0.sorted() } == (hasSink ? Array(0..<UInt64(80)) : []))
    }

    @Test
    func `context ordering follows declarations and stable fallback identities`() throws {
        let first = attachmentID("z-declared")
        let second = attachmentID("a-declared")
        let firstTrack = TrackID(attachmentID: first, key: TrackKey(rawValue: "z-track"))
        let secondTrack = TrackID(attachmentID: first, key: TrackKey(rawValue: "a-track"))
        let attachment = try ScenarioAttachment(id: first)
            .adding(SequentialTrack<Int>(id: firstTrack))
            .adding(SequentialTrack<Int>(id: secondTrack))
        let definition = try ScenarioDefinition(
            id: ScenarioID(rawValue: "ordered"), defaultMode: .record,
            attachments: [attachment, ScenarioAttachment(id: second)])
        let reporter = DiagnosticReporter(definition: definition)
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
        #expect(reporter.report.diagnostics.map(\.diagnostic.context) == contexts)
        #expect(contexts[3].attachmentID == first)
        #expect(contexts[3].trackID == firstTrack)
        #expect(contexts[0].attachmentID == nil)
        #expect(contexts[1].trackID == nil)
    }

    @Test(arguments: [false, true])
    func `post finish reporting remains inspectable without changing frozen facts`(hasSink: Bool) async throws {
        let calls = Mutex(0)
        let sink = DiagnosticSink { _ in calls.withLock { $0 += 1 } }
        let reporter = try makeReporter(sink: hasSink ? sink : nil)
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
        #expect(reporter.postFinishDiagnostics.map(\.sequence) == Array(1...UInt64(40)))
        #expect(calls.withLock { $0 } == (hasSink ? 41 : 0))
    }

    @Test
    func `blocked callback allows inspection and freeze then retains its failure in late log`() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let inspections = Mutex(0)
        let reporter = try makeReporter(sink: DiagnosticSink { _ in
            entered.signal()
            #expect(release.wait(timeout: .now() + 5) == .success)
            throw SinkError(onDescription: { inspections.withLock { $0 += 1 } })
        })
        DispatchQueue.global().async {
            reporter.record(Diagnostic(issue: .system(DiagnosticLabel("blocked"))))
            completed.signal()
        }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        #expect(reporter.report.diagnostics.count == 1)
        let frozen = reporter.freeze()
        release.signal()
        #expect(completed.wait(timeout: .now() + 5) == .success)
        #expect(reporter.report == frozen)
        #expect(reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [.sinkFailed])
        #expect(inspections.withLock { $0 } == 0)
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
        return try DiagnosticReporter(definition: ScenarioDefinition(
            id: ScenarioID(rawValue: "ownership"), defaultMode: .replay, attachments: [attachment]))
    }

    private func makeReporter(sink: DiagnosticSink? = nil) throws -> DiagnosticReporter {
        try DiagnosticReporter(definition: ScenarioDefinition(
            id: ScenarioID(rawValue: "diagnostics"), defaultMode: .record), sink: sink)
    }

    private func attachmentID(_ key: String) -> AttachmentID {
        AttachmentID(systemTypeID: SystemTypeID(rawValue: "example"), key: AttachmentKey(rawValue: key))
    }

    private func trackID(_ key: String) -> TrackID {
        TrackID(attachmentID: attachmentID("primary"), key: TrackKey(rawValue: key))
    }
}
