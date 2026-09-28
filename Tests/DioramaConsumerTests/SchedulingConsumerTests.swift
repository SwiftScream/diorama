import DioramaCore
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SchedulingConsumerTests {
    @Test
    func `a public consumer system cancels work and scopes delivery through finish`() async throws {
        let setup = try start()
        let execution = setup.execution
        let scheduling = setup.scheduling
        let record = setup.record
        let canceled: ScheduledItemHandle = try scheduling.schedule(after: .seconds(60), for: record) {
            Issue.record("Canceled work must not run")
        }
        #expect(canceled.cancel())

        let handoff = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let delivered = try scheduling.schedule(after: .milliseconds(5), for: record) {
            handoff.continuation.finish()
            for await _ in release.stream {}
            execution.reporter.record(Diagnostic(issue: .system(DiagnosticLabel("async-delivery"))))
        }
        for await _ in handoff.stream {}
        #expect(!delivered.cancel())
        let finish = Task { await execution.finish() }
        release.continuation.finish()
        let result = await finish.value
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.system(DiagnosticLabel("async-delivery"))])
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
        #expect(!delivered.cancel())
    }

    @Test
    func `a public consumer scopes async delivery across an actor hop`() async throws {
        let setup = try start()
        let execution = setup.execution
        let scheduling = setup.scheduling
        let record = setup.record
        let receiver = Receiver()
        let entry = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let handle = try scheduling.schedule(after: .milliseconds(5), for: record, delivery: {
            entry.continuation.finish()
            for await _ in release.stream {}
            await receiver.receive()
        })
        for await _ in entry.stream {}
        #expect(!handle.cancel())
        let finish = Task { await execution.finish() }
        release.continuation.finish()
        #expect(await finish.value.report.diagnostics.isEmpty)
        #expect(await receiver.count == 1)
    }

    private actor Receiver {
        var count = 0
        func receive() {
            count += 1
        }
    }

    private struct Setup {
        let execution: ScenarioExecution
        let scheduling: SchedulingLease
        let record: RecordIdentity
    }

    private func start() throws -> Setup {
        let type = ScenarioSystemType("scheduled-consumer")
        let id = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: "consumer"))
        let track = TrackID(attachmentID: id, key: TrackKey(rawValue: "events"))
        let attachment = try ScenarioAttachment(id: id).adding(SequentialTrack<Int>(id: track))
        let system = try ScenarioSystem(type: type, attachment: attachment) { context in
            _ = try context.lease(for: track, preparation: ValuePreparation<Int>())
            return PreparedSystem { ActivatedSystem(dependency: context.scheduling, deactivate: {}) }
        }
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [attachment]), scenarioID: ScenarioID(rawValue: "consumer"),
            defaultMode: .replay, systems: [AnyScenarioSystem(system)])
        let scheduling = try execution.dependency(system)
        let record = RecordIdentity(trackID: track, sequence: 0)
        return Setup(execution: execution, scheduling: scheduling, record: record)
    }
}
