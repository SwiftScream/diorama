@testable import DioramaCore
import Synchronization
import Testing

struct ValuePreparationTests {
    private struct Payload: Equatable, Sendable, CustomStringConvertible {
        var field: String
        var value: String
        var description: String {
            "SECRET-PAYLOAD"
        }
    }

    private struct NativeError: Error, CustomStringConvertible {
        let onDescription: @Sendable () -> Void
        var description: String {
            onDescription()
            return "SECRET-NATIVE-ERROR"
        }
    }

    @Test
    func `ordered typed policy admits only redacted normalized validated content`() throws {
        let stages = Mutex<[String]>([])
        let reporter = try makeReporter()
        let policy = ValuePreparation<Payload>(
            canonicalize: { value in
                stages.withLock { $0.append("canonicalize") }
                return Payload(field: value.field.lowercased(), value: value.value)
            },
            redact: { value in
                stages.withLock { $0.append("redact") }
                #expect(value.field == "authorization")
                return Payload(field: value.field, value: "safe-token")
            },
            normalize: { value in
                stages.withLock { $0.append("normalize") }
                #expect(value.value == "safe-token")
                return value
            },
            validate: { value in
                stages.withLock { $0.append("validate") }
                #expect(value == Payload(field: "authorization", value: "safe-token"))
            })
        let prepared = try policy.prepare(
            capturing: { Payload(field: "Authorization", value: "SECRET-TOKEN") },
            purpose: .recording, reporter: reporter)
        let track = SequentialTrack(id: trackID(), values: [prepared])
        #expect(track.records.map(\.value) == [Payload(field: "authorization", value: "safe-token")])
        #expect(stages.withLock { $0 } == ["canonicalize", "redact", "normalize", "validate"])
        #expect(reporter.report.diagnostics.isEmpty)
        #expect(reporter.report.recordingHealth.isHealthy)

        let repeated = try policy.prepare(capturing: { prepared.value }, purpose: .replay, reporter: reporter)
        #expect(repeated.value == prepared.value)
    }

    @Test(arguments: 0..<5)
    func `every failed stage stops admission and records only safe health evidence`(failureIndex: Int) throws {
        let stages = Mutex<[Int]>([])
        let inspections = Mutex(0)
        let reference = Mutex<DiagnosticReporter?>(nil)
        defer { reference.withLock { $0 = nil } }
        let sink = DiagnosticSink { entry in
            let reporter = try #require(reference.withLock { $0 })
            #expect(reporter.report.recordingHealth.failures == [entry])
            #expect(!String(reflecting: entry).contains("SECRET"))
        }
        let reporter = try makeReporter(sink: sink)
        reference.withLock { $0 = reporter }
        let step: @Sendable (Int, Payload) throws -> Payload = { index, value in
            stages.withLock { $0.append(index) }
            if index == failureIndex {
                throw NativeError(onDescription: { inspections.withLock { $0 += 1 } })
            }
            return value
        }
        let policy = ValuePreparation<Payload>(
            canonicalize: { try step(1, $0) },
            redact: { try step(2, $0) },
            normalize: { try step(3, $0) },
            validate: { _ = try step(4, $0) })
        let context = DiagnosticContext.record(RecordIdentity(trackID: trackID(), sequence: 3))
        do {
            _ = try policy.prepare(
                capturing: { try step(0, Payload(field: "Authorization", value: "SECRET-TOKEN")) },
                purpose: .recording, reporter: reporter, context: context,
                fieldPath: [DiagnosticLabel("headers"), DiagnosticLabel("authorization")],
                rule: DiagnosticLabel("credential-policy"))
            Issue.record("Failed preparation unexpectedly produced an admissible value")
        } catch {
            #expect(error.diagnostic.issue == failureIssues[failureIndex])
            #expect(error.diagnostic.context == context)
            #expect(error.diagnostic.rule == DiagnosticLabel("credential-policy"))
            #expect(error.diagnostic.fieldPath.map(\.text) == ["headers", "authorization"])
            #expect(error.diagnostic.recordingImpact == .invalidatesCandidate)
            #expect(!String(reflecting: error).contains("SECRET"))
        }
        #expect(stages.withLock { $0 } == Array(0...failureIndex))
        #expect(inspections.withLock { $0 } == 0)
        #expect(reporter.report.diagnostics.count == 1)
        #expect(!reporter.report.recordingHealth.isHealthy)
        #expect(!String(reflecting: reporter.report).contains("SECRET"))
    }

    @Test
    func `replay preparation failure yields structured startup evidence without recording damage`() throws {
        let reporter = try makeReporter()
        let inspections = Mutex(0)
        let policy = ValuePreparation<String>(validate: { _ in
            throw NativeError(onDescription: { inspections.withLock { $0 += 1 } })
        })
        #expect(throws: PreparationFailure.self) {
            try policy.prepare(capturing: { "SECRET-EDITED-INPUT" }, purpose: .replay, reporter: reporter)
        }
        let startupFailure = ScenarioStartupFailure(report: reporter.report)
        #expect(startupFailure.report.diagnostics.map(\.diagnostic.issue) == [.preparationFailed(.validation)])
        #expect(startupFailure.report.recordingHealth.isHealthy)
        #expect(!String(reflecting: startupFailure).contains("SECRET"))
        #expect(inspections.withLock { $0 } == 0)
    }

    @Test
    func `failed recording preserves the consumer live result and does not recover health`() throws {
        let reporter = try makeReporter()
        let inspections = Mutex(0)
        let failing = ValuePreparation<String>(redact: { _ in
            throw NativeError(onDescription: { inspections.withLock { $0 += 1 } })
        })
        let liveResult = Payload(field: "native-result", value: "SECRET-LIVE-VALUE")
        let observed = Result {
            try failing.prepare(capturing: { liveResult.value }, purpose: .recording, reporter: reporter)
        }
        #expect(liveResult.value == "SECRET-LIVE-VALUE")
        if case .success = observed {
            Issue.record("Failed capture was admitted")
        }
        let succeeding = ValuePreparation<String>()
        let prepared = try succeeding.prepare(capturing: { "safe" }, purpose: .recording, reporter: reporter)
        #expect(prepared.value == "safe")
        #expect(reporter.report.recordingHealth.failures.count == 1)
        #expect(!reporter.report.recordingHealth.isHealthy)
    }

    private var failureIssues: [DiagnosticIssue] {
        [
            .conversionFailed,
            .preparationFailed(.canonicalization),
            .preparationFailed(.redaction),
            .preparationFailed(.normalization),
            .preparationFailed(.validation),
        ]
    }

    private func makeReporter(sink: DiagnosticSink? = nil) throws -> DiagnosticReporter {
        try DiagnosticReporter(definition: ScenarioDefinition(
            id: ScenarioID(rawValue: "preparation"), defaultMode: .record), sink: sink)
    }

    private func trackID() -> TrackID {
        TrackID(
            attachmentID: AttachmentID(
                systemTypeID: SystemTypeID(rawValue: "consumer"), key: AttachmentKey(rawValue: "primary")),
            key: TrackKey(rawValue: "events"))
    }
}
