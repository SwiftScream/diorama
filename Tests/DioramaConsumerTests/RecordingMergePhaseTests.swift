import DioramaCore
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RecordingMergePhaseTests {
    @Test
    func `all tracks freeze and runtime owners release before ordered once only merges`() async throws {
        let journal = ResourceJournal()
        let execution = try await start(journal: journal)
        let result = await execution.finish()
        #expect(await execution.finish().report == result.report)
        let events = journal.values
        let firstMerge = try #require(events.firstIndex { $0.hasPrefix("merge-") })
        #expect(events[..<firstMerge].filter { $0.hasPrefix("freeze-") } == [
            "freeze-a-first", "freeze-a-second", "freeze-b-first", "freeze-b-second",
        ])
        #expect(events[..<firstMerge].filter { $0.hasPrefix("release-") }.count == 8)
        #expect(Array(events[firstMerge...]) == [
            "merge-a-first", "merge-a-second", "merge-b-first", "merge-b-second",
        ])
        let definition = try #require(result.definition)
        for attachment in definition.attachments {
            for id in attachment.trackIDs {
                let track = try #require(try attachment.track(id, as: Int.self))
                #expect(track.records.map(\.value) == [42])
            }
        }
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.usage.flatMap(\.tracks).allSatisfy {
            $0.activity == .record(recordedCount: 1, incompleteCount: 0)
        })
    }

    @Test(arguments: ["freeze", "validation"])
    func `later track capture failure prevents every merge and misleading merge failure`(failure: String) async throws {
        let journal = ResourceJournal()
        let execution = try await start(journal: journal, failure: failure)
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(!journal.values.contains { $0.hasPrefix("merge-") })
        #expect(journal.values.filter { $0.hasPrefix("freeze-") }.count == 4)
        #expect(journal.values.filter { $0.hasPrefix("release-") }.count == 8)
        let issue: DiagnosticIssue = failure == "freeze"
            ? .verification(.recordingNotAdmitted) : .preparationFailed(.validation)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [issue])
        #expect(result.report.diagnostics.first?.diagnostic.context.recordIdentity?.trackID.key.rawValue == "second")
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
    }

    @Test(arguments: ["state", "dependency", "accumulator"])
    func `required release invalidation prevents all candidate merges`(failure: String) async throws {
        let journal = ResourceJournal()
        let execution = try await start(journal: journal, failure: failure)
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(!journal.values.contains { $0.hasPrefix("merge-") })
        #expect(journal.values.filter { $0.hasPrefix("release-") }.count == 8)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.system(DiagnosticLabel("release-invalidates"))])
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
    }

    @Test
    func `failed merge prevents later merges after complete capture and release`() async throws {
        let journal = ResourceJournal()
        let execution = try await start(journal: journal, failure: "merge")
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(journal.values.filter { $0.hasPrefix("merge-") } == ["merge-a-first"])
        #expect(journal.values.filter { $0.hasPrefix("freeze-") }.count == 4)
        #expect(journal.values.filter { $0.hasPrefix("release-") }.count == 8)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.verification(.recordingMergeFailed)])
    }

    @Test(arguments: [ScenarioMode.replay, .passthrough])
    func `non recording modes never invoke merge`(mode: ScenarioMode) async throws {
        let journal = ResourceJournal()
        let execution = try await start(journal: journal, mode: mode)
        let result = await execution.finish()
        #expect(result.definition != nil)
        #expect(result.report.diagnostics.isEmpty)
        #expect(journal.values.isEmpty)
    }

    @Test
    func `rollback freezes accepted records and releases owners without merging`() async throws {
        let journal = ResourceJournal()
        do {
            _ = try await start(journal: journal, failure: "startup")
            Issue.record("Failed activation published an execution")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.report.diagnostics.map(\.diagnostic.issue) == [.lifecycle(.activationFailed)])
        }
        #expect(!journal.values.contains { $0.hasPrefix("merge-") })
        #expect(journal.values.filter { $0.hasPrefix("freeze-") } == ["freeze-a-first", "freeze-a-second"])
        #expect(journal.values.filter { $0.hasPrefix("release-") }.count == 4)
    }

    private func start(journal: ResourceJournal, failure: String = "", mode: ScenarioMode = .record)
        async throws -> ScenarioExecution
    {
        let first = try ScenarioSystem(named: "a", definition: MergePhaseDefinition(journal: journal,
                                                                                    failure: failure))
        let second = try ScenarioSystem(named: "b", definition: MergePhaseDefinition(journal: journal,
                                                                                     failure: failure))
        return try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [first.attachment, second.attachment]),
            scenarioID: .init(rawValue: "merge-phases"), defaultMode: mode,
            systems: [AnyScenarioSystem(second), AnyScenarioSystem(first)])
    }
}

private struct MergePhaseState: Sendable {
    let key: String
    let tracks: [HeaderlessSequentialTrackLease<Int>]
    var witness: ResourceReleaseWitness?
    var value = 0
}

private struct MergePhaseDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.merge-phases")
    let journal: ResourceJournal
    let failure: String

    var tracks: [AnyTrackDefinition] {
        [track("first").erased, track("second").erased]
    }

    private func track(_ key: String) -> TrackDefinition<Int, Void> {
        TrackDefinition(key, preparation: .init(validate: { value in
            if value < 0 {
                throw ResourceTestFailure.expected
            }
        }), mergeRecording: { _, fresh in
            journal.append("merge-" + fresh.id.attachmentID.key.rawValue + "-" + key)
            if !failure.isEmpty {
                throw ResourceTestFailure.expected
            }
            return fresh
        })
    }

    func makeRecordState(in context: borrowing SystemStateContext) throws -> MergePhaseState {
        if context.attachmentID.key.rawValue == "b", failure == "startup" {
            throw ResourceTestFailure.expected
        }
        return try MergePhaseState(key: context.attachmentID.key.rawValue,
                                   tracks: [context.lease(for: track("first")), context.lease(for: track("second"))])
    }

    func makeReplayState(in _: borrowing SystemStateContext) {}

    func makeRecordDependency(using execution: SystemExecution<MergePhaseState>) throws -> ResourceReleaseWitness {
        try execution.state.withLock { state, operation in
            let key = state.key
            state.witness = witness("state", key: key, reporter: execution.reporter)
            for lease in state.tracks {
                let last = key == "b" && lease.id.key.rawValue == "second"
                let label = key + "-" + lease.id.key.rawValue
                _ = try operation.beginRecord(on: lease, preparation: .init(validate: { value in
                    if value < 0 {
                        throw ResourceTestFailure.expected
                    }
                }), capturing: { _ in
                    witness("accumulator", key: last ? "b" : "a", reporter: execution.reporter, label: label)
                }, freeze: { state, accumulator in
                    journal.append("freeze-" + label)
                    withExtendedLifetime(accumulator) {}
                    if last && failure == "freeze" {
                        return nil
                    }
                    return last && failure == "validation" ? -1 : state.value
                })
            }
            return witness("dependency", key: key, reporter: execution.reporter)
        }
    }

    func makeReplayDependency(using _: SystemExecution<Void>) -> ResourceReleaseWitness {
        ResourceReleaseWitness {}
    }

    func makePassthroughDependency(using _: SystemExecution<Void>) -> ResourceReleaseWitness {
        ResourceReleaseWitness {}
    }

    func cleanUpRecord(using lifecycle: borrowing SystemLifecycleContext<MergePhaseState>,
                       dependency _: ResourceReleaseWitness?) -> SystemCleanupResult
    {
        try? lifecycle.state.withLock { $0.value = 42 }
        return .completed
    }

    private func witness(_ phase: String, key: String, reporter: DiagnosticReporter,
                         label: String? = nil) -> ResourceReleaseWitness
    {
        ResourceReleaseWitness {
            journal.append("release-" + (label ?? key) + "-" + phase)
            if key == "b", failure == phase {
                reporter.record(Diagnostic(issue: .system(DiagnosticLabel("release-invalidates")),
                                           recordingImpact: .invalidatesCandidate))
            }
        }
    }
}
