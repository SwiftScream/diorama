import DioramaCore
import Testing

struct ScenarioEvaluationTests {
    @Test
    func `known dependency lookup failures participate in attachment evaluation`() async throws {
        let key = AttachmentKey(rawValue: "a")
        let execution = try ScenarioExecution.start(
            definition: ExecutionFixtures.definition(["a"]),
            scenarioID: ScenarioID(rawValue: "execution"), defaultMode: .replay,
            systems: [
                ExecutionFixtures.system("a", journal: ExecutionFixtures.Journal()),
            ])
        let known = DependencyKey<String>(attachmentID: ExecutionFixtures.attachment("a"))
        let missing = DependencyKey<String>(attachmentID: ExecutionFixtures.attachment("missing"))
        #expect(throws: DependencyAccessFailure.self) { try execution.dependency(known) }
        #expect(throws: DependencyAccessFailure.self) {
            try execution.dependency(missing)
        }
        let result = await execution.finish()
        #expect(result.report.diagnostics.map(\.diagnostic.context) == [
            .attachment(known.attachmentID), .attachment(missing.attachmentID),
        ])
        #expect(result.evaluate(.noUnexpectedOperations, attachments: [key]).failures == [
            .diagnostic(result.report.diagnostics[0]),
        ])
        #expect(result.evaluate(.noUnexpectedOperations).failures.count == 2)
        #expect(throws: DependencyAccessFailure.self) { try execution.dependency(known) }
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.context) == [
            .attachment(ExecutionFixtures.attachment("a")),
        ])
    }

    @Test
    func `evaluation selects attachment facts without treating scope typos as success`() async throws {
        let journal = ExecutionFixtures.Journal()
        let execution = try ScenarioExecution.start(
            definition: ExecutionFixtures.definition(["a", "b"]),
            scenarioID: ScenarioID(rawValue: "execution"), defaultMode: .replay,
            systems: [
                ExecutionFixtures.system("a", journal: journal),
                ExecutionFixtures.system("b", journal: journal, failCleanup: true),
            ])
        let first = try execution.dependency(
            ExecutionFixtures.dependencyKey("a", as: SequentialTrackLease<Int>.self))
        #expect(first.report(.system(DiagnosticLabel("custom"))))
        execution.reporter.record(Diagnostic(issue: .conversionFailed, recordingImpact: .invalidatesCandidate))
        let result = await execution.finish()
        #expect(result.evaluate(.noUnexpectedOperations).isSatisfied)
        #expect(!result.evaluate(.noDiagnostics).isSatisfied)
        #expect(result.evaluate(.healthyRecording, attachments: [AttachmentKey(rawValue: "a")]).isSatisfied)
        #expect(!result.evaluate(.healthyRecording).isSatisfied)
        #expect(result.evaluate(.successfulCleanup, attachments: [AttachmentKey(rawValue: "a")]).isSatisfied)
        #expect(result.evaluate(.successfulCleanup).failures == [.cleanup(result.cleanup[1])])
        #expect(result.evaluate(.noDiagnostics, attachments: [AttachmentKey(rawValue: "a")]).failures.count == 1)
        #expect(result.evaluate(.noDiagnostics, attachments: []).isSatisfied)
        #expect(result.evaluate(.successfulCleanup, attachments: [
            AttachmentKey(rawValue: "z"), AttachmentKey(rawValue: "x"),
        ]).failures == [
            .unknownAttachment(AttachmentKey(rawValue: "x")), .unknownAttachment(AttachmentKey(rawValue: "z")),
        ])
        let before = result.evaluate(.noUnexpectedOperations)
        #expect(!first.report(.system(DiagnosticLabel("late"))))
        #expect(result.evaluate(.noUnexpectedOperations) == before)
        #expect(await execution.finish() == result)
        #expect(execution.reporter.postFinishDiagnostics.count == 1)
    }

    @Test
    func `empty runs satisfy every explicit condition`() async throws {
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(),
            scenarioID: ScenarioID(rawValue: "empty"), defaultMode: .record,
            systems: [])
        let result = await execution.finish()
        let conditions: [ScenarioEvaluationCondition] = [
            .noUnexpectedOperations, .noDiagnostics, .allRecordingsUsed, .healthyRecording, .successfulCleanup,
        ]
        for condition in conditions {
            #expect(result.evaluate(condition).condition == condition)
            #expect(result.evaluate(condition).isSatisfied)
        }
    }
}
