import Diorama
import DioramaCore
import Synchronization
import Testing

struct DioramaScopedDependencyLifetimeTests {
    private enum BodyFailure: Error, Equatable { case expected }

    @MainActor
    @Test(arguments: [ScenarioMode.record, .replay, .passthrough], [false, true])
    func `scoped arguments release before reports on actor isolated success and failure`(
        mode: ScenarioMode, fails: Bool) async throws
    {
        let probe = ScopedReleaseProbe()
        let system = try ScenarioSystem(named: "release", definition: ScopedReleaseDefinition(probe: probe))
        let number = try ScenarioSystem(named: "number", definition: LifecycleDefinition(factory: { 42 }))
        let baseline = try ScenarioDefinition(attachments: [system.attachment, number.attachment])
        let setup = try Diorama(definition: baseline, scenarioID: "scoped-release", mode: mode,
                                systems: system, number)
        var actorValue = 0
        do {
            let result = try await setup.execute { _, dependency, value async throws(BodyFailure) -> Int in
                actorValue += value
                await Task.yield()
                #expect(dependency.value == 42)
                #expect(probe.releases.withLock { $0 } == 0)
                if fails {
                    throw .expected
                }
                return actorValue
            }
            #expect(!fails)
            #expect(result.body == 42)
            #expect(result.definition == nil)
            #expect(result.report == setup.report)
        } catch {
            #expect(fails)
            #expect(error as? BodyFailure == .expected)
        }
        #expect(actorValue == 42)
        try checkRelease(probe, report: #require(setup.report))
    }

    @Test
    func `body cancellation releases scoped arguments before retaining its report`() async throws {
        let probe = ScopedReleaseProbe()
        let system = try ScenarioSystem(named: "release", definition: ScopedReleaseDefinition(probe: probe))
        let setup = try Diorama(scenarioID: "canceled-release", mode: .record, systems: system)
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            try await setup.execute { _, _ in
                started.continuation.yield(())
                try await Task.sleep(for: .seconds(60))
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("The original cancellation was lost")
        } catch {
            #expect(error is CancellationError)
        }
        try checkRelease(probe, report: #require(setup.report))
    }

    @Test
    func `external retention preserves dependency use and keeps later facts separate`() async throws {
        let probe = ScopedReleaseProbe()
        let system = try ScenarioSystem(named: "release", definition: ScopedReleaseDefinition(probe: probe))
        let saved = Mutex<ScopedReleaseDependency?>(nil)
        let result = try await Diorama(scenarioID: "retained-release", mode: .passthrough,
                                       systems: system).execute { _, dependency in
            saved.withLock { $0 = dependency }
        }
        #expect(saved.withLock { $0?.value } == 42)
        #expect(probe.releases.withLock { $0 } == 0)
        #expect(result.report.diagnostics.isEmpty)
        saved.withLock { $0 = nil }
        #expect(probe.releases.withLock { $0 } == 1)
        let reporter = try #require(probe.reporter.withLock { $0 })
        #expect(reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [releaseIssue])
        #expect(result.report.diagnostics.isEmpty)
    }

    private func checkRelease(_ probe: ScopedReleaseProbe, report: DioramaReport) {
        #expect(probe.releases.withLock { $0 } == 1)
        #expect(report.diagnostics.map(\.diagnostic.issue) == [releaseIssue])
        #expect(!report.candidate.isComplete)
        #expect(probe.reporter.withLock { $0?.postFinishDiagnostics.isEmpty } == true)
    }
}

private let releaseIssue = DiagnosticIssue.system(DiagnosticLabel("dependency-release"))

private final class ScopedReleaseProbe: Sendable {
    let releases = Mutex(0)
    let reporter = Mutex<DiagnosticReporter?>(nil)
}

private final class ScopedReleaseDependency: Sendable {
    let value = 42
    private let probe: ScopedReleaseProbe

    init(probe: ScopedReleaseProbe) {
        self.probe = probe
    }

    deinit {
        probe.releases.withLock { $0 += 1 }
        let reporter = probe.reporter.withLock { $0 }
        reporter?.record(Diagnostic(issue: releaseIssue, recordingImpact: .invalidatesCandidate))
    }
}

private struct ScopedReleaseDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.scoped-release")
    let probe: ScopedReleaseProbe

    func makeRecordState(in _: borrowing SystemStateContext) {}
    func makeReplayState(in _: borrowing SystemStateContext) {}

    func makeRecordDependency(using execution: SystemExecution<Void>) -> ScopedReleaseDependency {
        probe.reporter.withLock { $0 = execution.reporter }
        return ScopedReleaseDependency(probe: probe)
    }

    func makeReplayDependency(using execution: SystemExecution<Void>) -> ScopedReleaseDependency {
        makeRecordDependency(using: execution)
    }

    func makePassthroughDependency(using execution: SystemExecution<Void>) -> ScopedReleaseDependency {
        makeRecordDependency(using: execution)
    }
}
