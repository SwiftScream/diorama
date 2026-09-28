@testable import DioramaCore
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct GroupedLifecycleValidationTests {
    private enum CaptureError: Error { case failed }

    @Test
    func `invalid transitions reject events and invalidate the candidate`() async throws {
        let clock = SchedulerTestClock()
        let (execution, dependency) = try GroupedFixtures.setup(clock: clock)
        let time = dependency.time
        let reporter = dependency.reporter
        let preparation = ValuePreparation<GroupedFixtures.Interaction>()
        let first = try dependency.interactions.beginInteraction(at: time.capture(), preparation: preparation) {
            try GroupedFixtures.prepared("first", reporter: reporter)
        }
        let other = try dependency.interactions.beginInteraction(at: time.capture(), preparation: preparation) {
            try GroupedFixtures.prepared("other", reporter: reporter)
        }
        let phase = try first.observe(at: time.capture()) { try GroupedFixtures.prepared("phase", reporter: reporter) }
        #expect(throws: GroupedLifecycleFailure.self) {
            try other.respond(to: phase, at: time.capture()) {
                try GroupedFixtures.prepared("wrong", reporter: reporter)
            }
        }
        try first.respond(to: phase, at: time.capture()) { try GroupedFixtures.prepared("right", reporter: reporter) }
        #expect(throws: GroupedLifecycleFailure.self) {
            try first.respond(to: phase, at: time.capture()) {
                try GroupedFixtures.prepared("again", reporter: reporter)
            }
        }
        try first.returned(at: time.capture()) { try GroupedFixtures.prepared("done", reporter: reporter) }
        #expect(throws: GroupedLifecycleFailure.self) {
            try first.failed(at: time.capture()) { try GroupedFixtures.prepared("failed", reporter: reporter) }
        }
        #expect(throws: GroupedLifecycleFailure.self) {
            try first.observe(at: time.capture()) { try GroupedFixtures.prepared("late", reporter: reporter) }
        }
        let postCapture = try time.capture()
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.grouped(.duplicateDecision)), .sequential(.grouped(.duplicateConclusion)),
            .sequential(.grouped(.afterConclusion)), .sequential(.grouped(.unknownPhase)),
        ])
        #expect(!result.report.recordingHealth.isHealthy)
        #expect(throws: GroupedLifecycleFailure.self) {
            try first.observe(at: postCapture) { try GroupedFixtures.prepared("post", reporter: reporter) }
        }
        #expect(execution.reporter.postFinishDiagnostics.last?.diagnostic.issue
            == .sequential(.grouped(.lateObservation)))
    }

    @Test
    func `failed group capture and final validation suppress the candidate`() async throws {
        let clock = SchedulerTestClock()
        let (execution, dependency) = try GroupedFixtures.setup(clock: clock)
        let time = dependency.time
        let reporter = dependency.reporter
        #expect(throws: SequentialOperationFailure.self) {
            try dependency.interactions.beginInteraction(at: time.capture(),
                                                         preparation: ValuePreparation<GroupedFixtures.Interaction>())
            { throw CaptureError.failed }
        }
        let rejecting = ValuePreparation<GroupedFixtures.Interaction>(validate: { _ in throw CaptureError.failed })
        _ = try dependency.interactions.beginInteraction(at: time.capture(), preparation: rejecting) {
            try GroupedFixtures.prepared("valid-input", reporter: reporter)
        }
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.usage[0].tracks[0].activity == .record(recordedCount: 0, incompleteCount: 2))
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .conversionFailed, .preparationFailed(.validation),
        ])
        #expect(result.report.recordingHealth.failures.count == 2)
    }

    @Test
    func `subscription rejects a second terminal and delivery after completion`() async throws {
        let clock = SchedulerTestClock()
        let (execution, dependency) = try GroupedFixtures.setup(clock: clock)
        let reporter = dependency.reporter
        let time = dependency.time
        let stream = try dependency.subscriptions.beginSubscription(
            at: time.capture(), preparation: ValuePreparation<GroupedFixtures.Subscription>())
        { try GroupedFixtures.prepared("stream", reporter: reporter) }
        try stream.finish(at: time.capture())
        #expect(throws: GroupedLifecycleFailure.self) { try stream.finish() }
        #expect(throws: GroupedLifecycleFailure.self) {
            try stream.deliver(at: time.capture()) { try GroupedFixtures.prepared("late", reporter: reporter) }
        }
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .sequential(.grouped(.duplicateConclusion)), .sequential(.grouped(.afterConclusion)),
        ])
    }

    @Test
    func `capture from another execution invalidates the group candidate`() async throws {
        let clock = SchedulerTestClock()
        let (execution, dependency) = try GroupedFixtures.setup(clock: clock)
        let (otherExecution, other) = try GroupedFixtures.setup(clock: clock)
        let stream = try dependency.subscriptions.beginSubscription(
            at: dependency.time.capture(), preparation: ValuePreparation<GroupedFixtures.Subscription>())
        { try GroupedFixtures.prepared("stream", reporter: dependency.reporter) }
        let foreign = try other.time.capture()
        #expect(throws: GroupedLifecycleFailure.self) {
            try stream.deliver(at: foreign) { try GroupedFixtures.prepared("foreign", reporter: dependency.reporter) }
        }
        let result = await execution.finish()
        #expect(result.definition == nil)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .logicalTime(.foreignCapture), .sequential(.grouped(.invalidTiming)),
        ])
        #expect(await (otherExecution.finish()).report.recordingHealth.isHealthy)
    }

    @Test
    func `complete group validation runs without repeating capture transformations`() async throws {
        let clock = SchedulerTestClock()
        let (execution, dependency) = try GroupedFixtures.setup(clock: clock)
        let reporter = dependency.reporter
        let counts = Mutex((normalizations: 0, validations: 0))
        let preparation = ValuePreparation<GroupedFixtures.Interaction>(normalize: { value in
            counts.withLock { $0.normalizations += 1 }
            return value
        }, validate: { _ in
            counts.withLock { $0.validations += 1 }
        })
        _ = try dependency.interactions.beginInteraction(at: dependency.time.capture(), preparation: preparation) {
            try GroupedFixtures.prepared("prepared-input", reporter: reporter)
        }
        let result = await execution.finish()
        #expect(try GroupedFixtures.interactions(in: result).count == 1)
        #expect(counts.withLock { $0.normalizations } == 0)
        #expect(counts.withLock { $0.validations } == 1)
    }

    @Test
    func `escaped grouped handles release execution time and recording ownership`() async throws {
        let escaped = try await finishedHandles()
        #expect(escaped.execution == nil)
        #expect(escaped.time == nil)
        #expect(escaped.lease.isClosed)
        #expect(throws: GroupedLifecycleFailure.self) {
            try escaped.group.observe(at: escaped.capture) {
                Issue.record("Closed group must not capture")
                throw CaptureError.failed
            }
        }
    }

    private struct EscapedHandles {
        let group: InteractionAccumulator<String, String, String, String, String>
        let lease: HeaderlessSequentialTrackLease<GroupedFixtures.Interaction>
        let capture: LogicalTimeCapture
        weak var execution: ScenarioExecution?
        weak var time: ExecutionTime?
    }

    private func finishedHandles() async throws -> EscapedHandles {
        let clock = SchedulerTestClock()
        let (execution, dependency) = try GroupedFixtures.setup(clock: clock)
        let capture = try dependency.time.capture()
        let group = try dependency.interactions.beginInteraction(
            at: capture, preparation: ValuePreparation<GroupedFixtures.Interaction>())
        { try GroupedFixtures.prepared("input", reporter: dependency.reporter) }
        let escaped = EscapedHandles(group: group, lease: dependency.interactions, capture: capture,
                                     execution: execution, time: dependency.time)
        #expect(await execution.finish().report.recordingHealth.isHealthy)
        return escaped
    }

    @Test
    func `immutable grouped values reject impossible timing`() throws {
        #expect(throws: GroupedLifecycleValidationIssue.negativeOffset) {
            try LifecycleMoment(offset: .milliseconds(-1), value: "before")
        }
        let early = try LifecycleMoment(offset: .milliseconds(2), value: "early")
        let late = try LifecycleMoment(offset: .milliseconds(3), value: "late")
        #expect(throws: GroupedLifecycleValidationIssue.decisionBeforeObservation) {
            try InteractionPhase(observation: late, decision: early)
        }
        let phases = try [
            InteractionPhase<String, String>(observation: late),
            InteractionPhase<String, String>(observation: early),
        ]
        #expect(throws: GroupedLifecycleValidationIssue.eventOrder) {
            try GroupedFixtures.Interaction(input: "input", phases: phases, conclusion: .openAtRecordingHorizon)
        }
        #expect(throws: GroupedLifecycleValidationIssue.conclusionBeforeObservation) {
            try GroupedFixtures.Subscription(input: "input", events: [.delivered(late)],
                                             conclusion: .finished(atTime: .milliseconds(1)))
        }
    }
}
