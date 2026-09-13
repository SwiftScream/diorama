import DioramaConsumerTestSupport
import DioramaCore
import Testing

struct ConsumerSequentialSystemTests {
    @Test
    func `consumer module records and replays non codable values`() async throws {
        let key = AttachmentKey(rawValue: "primary")
        let record = try start(mode: .record, key: key)
        let recorder = try record.dependency(for: key, as: ConsumerSequentialDependency.self)

        #expect(recorder.mode == .record)
        #expect(try recorder.next(capturing: { ConsumerStableValue(11) }) == ConsumerStableValue(11))
        #expect(try recorder.next(capturing: { ConsumerStableValue(12) }) == ConsumerStableValue(12))
        #expect(await record.finish().report.diagnostics.isEmpty)

        let replay = try start(
            mode: .replay,
            key: key,
            values: [ConsumerStableValue(11), ConsumerStableValue(12)])
        let player = try replay.dependency(for: key, as: ConsumerSequentialDependency.self)
        var liveCallCount = 0

        #expect(try player.next(capturing: {
            liveCallCount += 1
            return ConsumerStableValue(91)
        }) == ConsumerStableValue(11))
        #expect(try player.next(capturing: {
            liveCallCount += 1
            return ConsumerStableValue(92)
        }) == ConsumerStableValue(12))
        #expect(liveCallCount == 0)
        #expect(await replay.finish().report.diagnostics.isEmpty)
    }

    @Test
    func `consumer module passthrough stays live and leaves content untouched`() async throws {
        let key = AttachmentKey(rawValue: "live")
        let execution = try start(
            mode: .passthrough,
            key: key,
            values: [ConsumerStableValue(1), ConsumerStableValue(2)])
        let dependency = try execution.dependency(for: key, as: ConsumerSequentialDependency.self)
        var liveCallCount = 0

        #expect(try dependency.next(capturing: {
            liveCallCount += 1
            return ConsumerStableValue(21)
        }) == ConsumerStableValue(21))
        #expect(try dependency.next(capturing: {
            liveCallCount += 1
            return ConsumerStableValue(22)
        }) == ConsumerStableValue(22))
        #expect(liveCallCount == 2)
        #expect(await execution.finish().report.diagnostics.isEmpty)
    }

    @Test
    func `named consumer attachments keep independent modes and cursors`() async throws {
        let first = AttachmentKey(rawValue: "first")
        let second = AttachmentKey(rawValue: "second")
        let definition = try ScenarioDefinition(
            id: ScenarioID(rawValue: "consumer-independent"),
            defaultMode: .record,
            attachments: [
                ConsumerSequentialSystem.attachment(
                    key: first,
                    values: [ConsumerStableValue(1), ConsumerStableValue(2)],
                    modeOverride: .replay),
                ConsumerSequentialSystem.attachment(
                    key: second,
                    values: [ConsumerStableValue(10), ConsumerStableValue(20)],
                    modeOverride: .replay),
            ])
        let execution = try ScenarioExecution.start(
            definition: definition,
            systems: [
                ConsumerSequentialSystem.registration(for: second),
                ConsumerSequentialSystem.registration(for: first),
            ])
        let firstDependency = try execution.dependency(
            for: first,
            as: ConsumerSequentialDependency.self)
        let secondDependency = try execution.dependency(
            for: second,
            as: ConsumerSequentialDependency.self)

        #expect(firstDependency.mode == .replay)
        #expect(secondDependency.mode == .replay)
        #expect(try secondDependency.next(capturing: { ConsumerStableValue(99) }).number == 10)
        #expect(try firstDependency.next(capturing: { ConsumerStableValue(99) }).number == 1)
        #expect(try secondDependency.next(capturing: { ConsumerStableValue(99) }).number == 20)
        #expect(try firstDependency.next(capturing: { ConsumerStableValue(99) }).number == 2)
        #expect(await execution.finish().report.diagnostics.isEmpty)
    }

    @Test
    func `consumer diagnostics participate in finalization and closure`() async throws {
        let key = AttachmentKey(rawValue: "verification")
        let execution = try start(
            mode: .replay,
            key: key,
            values: [ConsumerStableValue(31), ConsumerStableValue(32)])
        let dependency = try execution.dependency(for: key, as: ConsumerSequentialDependency.self)

        #expect(try dependency.next(capturing: { ConsumerStableValue(99) }).number == 31)
        #expect(dependency.reportUnusedRecord())
        let result = await execution.finish()
        #expect(dependency.isClosed)
        #expect(result.cleanup.count == 1)
        #expect(result.cleanup.first?.attachmentID == ConsumerSequentialSystem.attachmentID(for: key))
        #expect(result.cleanup.first?.disposition == .completed)
        #expect(result.report.diagnostics.map(\.diagnostic.issue) == [
            .system(DiagnosticLabel("consumer-unused-record")),
        ])
        #expect(result.report.diagnostics.map(\.diagnostic.context) == [
            .track(ConsumerSequentialSystem.trackID(for: key)),
        ])

        var liveCalled = false
        do {
            _ = try dependency.next(capturing: {
                liveCalled = true
                return ConsumerStableValue(99)
            })
            Issue.record("Closed consumer dependency unexpectedly produced a value")
        } catch {
            #expect(error as? ConsumerSystemFailure == .closed)
        }
        #expect(!liveCalled)
        #expect(execution.reporter.postFinishDiagnostics.map(\.diagnostic.issue) == [
            .lifecycle(.leaseClosed),
        ])
    }

    private func start(
        mode: ScenarioMode,
        key: AttachmentKey,
        values: [ConsumerStableValue] = []) throws -> ScenarioExecution
    {
        let definition = try ScenarioDefinition(
            id: ScenarioID(rawValue: "consumer-" + key.rawValue),
            defaultMode: mode,
            attachments: [ConsumerSequentialSystem.attachment(key: key, values: values)])
        return try ScenarioExecution.start(
            definition: definition,
            systems: [ConsumerSequentialSystem.registration(for: key)])
    }
}
