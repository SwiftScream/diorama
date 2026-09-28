@testable import DioramaCore
import Testing

@Suite(.timeLimit(.minutes(1)))
struct GroupedLifecycleFailureTests {
    private enum CaptureError: Error { case failed }
    enum InteractionPoint: CaseIterable, Sendable { case observation, decision, returned, failed }
    enum SubscriptionPoint: CaseIterable, Sendable { case delivery, reported, failed }

    @Test(arguments: InteractionPoint.allCases)
    func `failed interaction field capture invalidates its entire group`(point: InteractionPoint) async throws {
        let clock = SchedulerTestClock()
        let (execution, dependency) = try GroupedFixtures.setup(clock: clock)
        let time = dependency.time
        let reporter = dependency.reporter
        let group = try dependency.interactions.beginInteraction(
            at: time.capture(), preparation: ValuePreparation<GroupedFixtures.Interaction>())
        { try GroupedFixtures.prepared("input", reporter: reporter) }
        switch point {
        case .observation:
            #expect(throws: GroupedLifecycleFailure.self) {
                try group.observe(at: time.capture()) { throw CaptureError.failed }
            }
        case .decision:
            let phase = try group.observe(at: time.capture()) {
                try GroupedFixtures.prepared("phase", reporter: reporter)
            }
            #expect(throws: GroupedLifecycleFailure.self) {
                try group.respond(to: phase, at: time.capture()) { throw CaptureError.failed }
            }
        case .returned:
            #expect(throws: GroupedLifecycleFailure.self) {
                try group.returned(at: time.capture()) { throw CaptureError.failed }
            }
        case .failed:
            #expect(throws: GroupedLifecycleFailure.self) {
                try group.failed(at: time.capture()) { throw CaptureError.failed }
            }
        }
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.grouped(.captureFailed)), .sequential(.grouped(.incompleteGroup)),
        ])
        #expect(result.usage[0].tracks[0].activity == .record(recordedCount: 0, incompleteCount: 1))
    }

    @Test(arguments: SubscriptionPoint.allCases)
    func `failed subscription field capture invalidates its entire group`(point: SubscriptionPoint) async throws {
        let clock = SchedulerTestClock()
        let (execution, dependency) = try GroupedFixtures.setup(clock: clock)
        let time = dependency.time
        let reporter = dependency.reporter
        let group = try dependency.subscriptions.beginSubscription(
            at: time.capture(), preparation: ValuePreparation<GroupedFixtures.Subscription>())
        { try GroupedFixtures.prepared("input", reporter: reporter) }
        switch point {
        case .delivery:
            #expect(throws: GroupedLifecycleFailure.self) {
                try group.deliver(at: time.capture()) { throw CaptureError.failed }
            }
        case .reported:
            #expect(throws: GroupedLifecycleFailure.self) {
                try group.reportNonterminalFailure(at: time.capture()) { throw CaptureError.failed }
            }
        case .failed:
            #expect(throws: GroupedLifecycleFailure.self) {
                try group.fail(at: time.capture()) { throw CaptureError.failed }
            }
        }
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.grouped(.captureFailed)), .sequential(.grouped(.incompleteGroup)),
        ])
        #expect(result.usage[0].tracks[1].activity == .record(recordedCount: 0, incompleteCount: 1))
    }

    @Test
    func `grouped diagnostics render as safe stable categories`() {
        let cases: [(GroupedLifecycleIssue, String)] = [
            (.incompleteGroup, "grouped-incomplete"),
            (.captureFailed, "grouped-capture-failed"),
            (.afterConclusion, "grouped-after-conclusion"),
            (.duplicateConclusion, "grouped-duplicate-conclusion"),
            (.unknownPhase, "grouped-unknown-phase"),
            (.duplicateDecision, "grouped-duplicate-decision"),
            (.lateObservation, "grouped-late-observation"),
            (.invalidTiming, "grouped-invalid-timing"),
        ]
        for (issue, expected) in cases {
            #expect(ReportText.issue(.sequential(.grouped(issue))) == expected)
        }
    }
}
