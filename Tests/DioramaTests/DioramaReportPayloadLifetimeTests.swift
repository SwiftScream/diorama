import Diorama
import DioramaCore
import Synchronization
import Testing

struct DioramaReportPayloadLifetimeTests {
    private enum BodyFailure: Error { case stopped }

    @Test
    func `reports release output payloads while successful results preserve them`() async throws {
        let releases = Mutex(0)
        let descriptions = Mutex(0)
        let system = try ScenarioSystem(named: "payload", definition: PayloadDefinition())
        let setup = try Diorama(scenarioID: "payload-lifetime", mode: .record, systems: system)
        let saved: DioramaReport
        do {
            let result = try await setup.execute { _, execution in
                _ = try execution.state.withLock { lease, operation in
                    try operation.record(on: lease, capturing: {
                        Payload(onRelease: { releases.withLock { $0 += 1 } },
                                onDescription: { descriptions.withLock { $0 += 1 } })
                    }, preparation: ValuePreparation<Payload>())
                }
                return 42
            }
            saved = result.report
            #expect(result.body == 42)
            #expect(saved == setup.report)
            #expect(saved.evaluated(.healthyRecording).isSatisfied)
            #expect(saved.publication.candidate.recordedCount == 1)
            #expect(!saved.rendered().contains("SECRET-PAYLOAD"))
            let definition = try #require(result.definition)
            let attachment = try #require(definition.attachments.first)
            let track = try #require(try attachment.track(attachment.trackIDs[0], as: Payload.self))
            #expect(track.records.count == 1)
            #expect(releases.withLock { $0 } == 0)
            withExtendedLifetime(result) {}
        }
        #expect(releases.withLock { $0 } == 1)
        #expect(setup.report == saved)
        do {
            _ = try await setup.execute { _, execution in
                _ = try execution.state.withLock { lease, operation in
                    try operation.record(on: lease, capturing: {
                        Payload(onRelease: { releases.withLock { $0 += 1 } },
                                onDescription: { descriptions.withLock { $0 += 1 } })
                    }, preparation: ValuePreparation<Payload>())
                }
                throw BodyFailure.stopped
            }
            Issue.record("Expected original body failure")
        } catch {
            #expect(error as? BodyFailure == .stopped)
        }
        #expect(releases.withLock { $0 } == 2)
        #expect(setup.report == saved)
        #expect(descriptions.withLock { $0 } == 0)
        #expect(saved.evaluated(.successfulCleanup).isSatisfied)
        withExtendedLifetime(setup) {}
    }
}

private final class Payload: Sendable, CustomStringConvertible {
    let onRelease: @Sendable () -> Void
    let onDescription: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void, onDescription: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
        self.onDescription = onDescription
    }

    var description: String {
        onDescription()
        return "SECRET-PAYLOAD"
    }

    deinit { onRelease() }
}

private struct PayloadDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("payload")
    let values = TrackDefinition<Payload, Void>("values")
    var tracks: [AnyTrackDefinition] {
        [values.erased]
    }

    func makeRecordState(in context: borrowing SystemStateContext) throws -> HeaderlessSequentialTrackLease<Payload> {
        try context.lease(for: values)
    }

    func makeReplayState(in context: borrowing SystemStateContext) throws -> HeaderlessSequentialTrackLease<Payload> {
        try context.lease(for: values)
    }

    func makeRecordDependency(using execution: SystemExecution<HeaderlessSequentialTrackLease<Payload>>)
        -> SystemExecution<HeaderlessSequentialTrackLease<Payload>>
    {
        execution
    }

    func makeReplayDependency(using execution: SystemExecution<HeaderlessSequentialTrackLease<Payload>>)
        -> SystemExecution<HeaderlessSequentialTrackLease<Payload>>
    {
        execution
    }

    func makePassthroughDependency(using _: SystemExecution<Void>) throws
        -> SystemExecution<HeaderlessSequentialTrackLease<Payload>>
    {
        throw Unsupported.passthrough
    }

    private enum Unsupported: Error { case passthrough }
}
