import DioramaCore
import Synchronization
import Testing

struct ScenarioReportRenderingTests {
    @Test
    func `finalization retains earlier facts before notifying the sink of cleanup failure`() async throws {
        let current = Mutex<DiagnosticReporter?>(nil)
        defer { current.withLock { $0 = nil } }
        let notifications = Mutex<[UInt64]>([])
        let sink = DiagnosticSink { entry in
            let reporter = try #require(current.withLock { $0 })
            #expect(reporter.report.diagnostics.contains(entry))
            #expect(reporter.report.diagnostics.contains {
                $0.diagnostic.issue == .system(DiagnosticLabel("earlier"))
            })
            notifications.withLock { $0.append(entry.sequence) }
        }
        let journal = ExecutionFixtures.Journal()
        let definition = try ExecutionFixtures.definition(["record"])
        let execution = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "ledger-before-sink"),
            defaultMode: .record,
            systems: [ExecutionFixtures.system("record", journal: journal, failCleanup: true)],
            sink: sink)
        current.withLock { $0 = execution.reporter }
        execution.reporter.record(Diagnostic(issue: .system(DiagnosticLabel("earlier"))))
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .system(DiagnosticLabel("earlier")), .lifecycle(.cleanupFailed),
        ])
        #expect(notifications.withLock { $0 } == [0, 1])
        #expect(result.report.recordingHealth.isHealthy)
        #expect(result.definition != nil)
    }

    @Test
    func `rendering uses declared order safe labels and an immutable golden report`() async throws {
        let journal = ExecutionFixtures.Journal()

        let base = try ExecutionFixtures.definition(["z", "a"])
        let execution = try ScenarioExecution.start(
            definition: base,
            scenarioID: ScenarioID(rawValue: "execution"),
            defaultMode: .replay,
            systems: [
                ExecutionFixtures.system("a", journal: journal, failCleanup: true),
                ExecutionFixtures.system("z", journal: journal),
            ])
        let first = try execution.dependency(
            ExecutionFixtures.dependencyKey("z", as: SequentialTrackLease<Int>.self))
        #expect(try first.claimNext().value == 1)
        execution.reporter.record(Diagnostic(issue: .system(DiagnosticLabel("safe\nlabel")),
                                             context: .track(ExecutionFixtures.track("a")),
                                             fieldPath: [DiagnosticLabel("body"), DiagnosticLabel("name")],
                                             rule: DiagnosticLabel("hide\"value"),
                                             recordingImpact: .invalidatesCandidate))
        let result = await execution.finish()
        let text = result.rendered()
        let issueLine = #"[0] system="consumer" key="a" track="values" system-issue "safe\u{a}label" "#
            + #"fields=["body", "name"] rule="hide\"value" invalidates-recording"#
        #expect(text == #"""
        Scenario "execution"
        Attachment system="consumer" key="z" replay usage=included
          Track "values" replay used=1 unused=1
            Unused record 1
        Attachment system="consumer" key="a" replay usage=included
          Track "values" replay used=0 unused=2
            Unused record 0
            Unused record 1
        Diagnostics 2
          [1] system="consumer" key="a" cleanup-failed
          \#(issueLine)
        Recording health unhealthy
        Cleanup system="consumer" key="z" completed
        Cleanup system="consumer" key="a" failed
        """#)
        #expect(!first.report(.system(DiagnosticLabel("late"))))
        #expect(await execution.finish().rendered() == text)
        #expect(journal.descriptions.withLock { $0 } == 0)
        #expect(!text.contains("SECRET-LIFECYCLE-ERROR"))
    }

    @Test
    func `rendering never inspects recorded values and escapes identity controls`() async throws {
        let descriptions = Mutex(0)
        let id = AttachmentID(systemTypeID: SystemTypeID(rawValue: "consumer\\type"),
                              key: AttachmentKey(rawValue: "tab\tkey\u{202e}"))
        let trackID = TrackID(attachmentID: id, key: TrackKey(rawValue: "lines\r\n\0"))
        let value = SecretValue { descriptions.withLock { $0 += 1 } }
        let track = try SequentialTrack(id: trackID, values: preparedValues([value]))

        let definition = try ScenarioDefinition(attachments: [ScenarioAttachment(id: id).adding(track)])
        let instance = try ScenarioSystem(
            type: ScenarioSystemType(id: definition.attachments[0].id.systemTypeID),
            attachment: definition.attachments[0])
        { context in
            let lease = try context.lease(for: trackID, preparation: ValuePreparation<SecretValue>())
            return PreparedSystem { ActivatedSystem(dependency: lease, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "quoted\"scenario"), defaultMode: .replay,
            systems: [AnyScenarioSystem(instance)])
        let result = await execution.finish()
        let text = result.rendered()
        #expect(text.contains(#"Scenario "quoted\"scenario""#))
        #expect(text.contains(#"system="consumer\\type" key="tab\u{9}key\u{202e}""#))
        #expect(text.contains(#"Track "lines\u{d}\u{a}\u{0}""#))
        #expect(text.contains("Recording health healthy"))
        #expect(!text.contains("SECRET-RECORD"))
        #expect(descriptions.withLock { $0 } == 0)
        #expect(result.evaluate(.allRecordingsUsed).failures == [
            .unusedRecord(RecordIdentity(trackID: trackID, sequence: 0)),
        ])
    }

    @Test
    func `rendering describes every baseline problem without underlying error text`() async throws {
        let definition = try ScenarioDefinition()
        let diagnostics = [
            Diagnostic(issue: .baseline(.invalidPersistenceConfiguration)),
            Diagnostic(issue: .baseline(.requiredBaselineUnavailable(.missing))),
            Diagnostic(issue: .baseline(.requiredBaselineUnavailable(.unreadable))),
            Diagnostic(issue: .baseline(.requiredBaselineUnavailable(.invalidDocument))),
            Diagnostic(issue: .baseline(.requiredBaselineUnavailable(.incompatibleEnvelope))),
            Diagnostic(issue: .baseline(.requiredBaselineUnavailable(.incompatibleSystem))),
            Diagnostic(issue: .baseline(.requiredBaselineUnavailable(.incompatibleSetup))),
            Diagnostic(issue: .baseline(.replayAttachmentMissing)),
            Diagnostic(issue: .baseline(.loadedAttachmentNotConfigured)),
            Diagnostic(issue: .baseline(.baselineIgnoredForRecording(.invalidDocument))),
        ]
        let execution = try ScenarioExecution.start(
            definition: definition, scenarioID: ScenarioID(rawValue: "baseline"), defaultMode: .record,
            systems: [],
            initialDiagnostics: diagnostics)
        let text = await execution.finish().rendered()

        for expected in [
            "invalid-persistence-configuration",
            "required-baseline-unavailable reason=missing",
            "required-baseline-unavailable reason=unreadable",
            "required-baseline-unavailable reason=invalid-document",
            "required-baseline-unavailable reason=incompatible-envelope",
            "required-baseline-unavailable reason=incompatible-system",
            "required-baseline-unavailable reason=incompatible-setup",
            "replay-attachment-missing",
            "loaded-attachment-not-configured preservation=discarded",
            "baseline-ignored-for-recording reason=invalid-document preservation=lost",
        ] {
            #expect(text.contains(expected))
        }
        #expect(!text.contains("SECRET"))
    }
}

private final class SecretValue: Sendable, CustomStringConvertible {
    let descriptions: @Sendable () -> Void

    init(descriptions: @escaping @Sendable () -> Void) {
        self.descriptions = descriptions
    }

    var description: String {
        descriptions()
        return "SECRET-RECORD"
    }
}
