import DioramaCore
import Synchronization
import Testing

struct RecordingHeaderLifetimeTests {
    @Test(arguments: [false, true])
    func `replaced headers release after managed state commits even when preparation throws`(
        replacementFails: Bool) async throws
    {
        let definition = try HeaderDefinition()
        let system = try ScenarioSystem(named: "header", definition: definition)
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]),
            scenarioID: .init(rawValue: "header-release"), defaultMode: .record,
            systems: [AnyScenarioSystem(system)])
        let runtime = try execution.dependency(system)
        let observedVersions = Mutex<[Int]>([])
        try runtime.state.withLock { state, operation in
            try operation.setHeader(on: state.track, capturing: {
                HeaderValue(1) {
                    do {
                        let version = try runtime.state.withLock { state, _ in state.version }
                        observedVersions.withLock { $0.append(version) }
                    } catch {
                        Issue.record("Header destruction cannot reenter committed State: \(error)")
                    }
                }
            }, preparation: .init())
        }
        let replace = {
            try runtime.state.withLock { state, operation in
                defer {
                    #expect(observedVersions.withLock { $0.isEmpty })
                    state.version = 1
                }
                try operation.setHeader(on: state.track, capturing: { HeaderValue(2) },
                                        preparation: .init(validate: { _ in
                                            if replacementFails {
                                                throw RejectedHeader()
                                            }
                                        }))
            }
        }
        if replacementFails {
            #expect(throws: SequentialOperationFailure.self) { try replace() }
        } else {
            try replace()
        }
        #expect(observedVersions.withLock { $0 } == [1])

        let result = await execution.finish()
        try expectOutcome(result, trackID: TrackID(attachmentID: system.attachment.id, key: definition.values.key),
                          replacementFails: replacementFails)
        #expect(observedVersions.withLock { $0 } == [1])
    }

    private func expectOutcome(_ result: ScenarioFinalizationResult, trackID: TrackID,
                               replacementFails: Bool) throws
    {
        if replacementFails {
            #expect(result.definition == nil)
            #expect(result.report.diagnostics.map(\.diagnostic.issue) == [.preparationFailed(.validation)])
            #expect(!result.report.recordingHealth.isHealthy)
        } else {
            let candidate = try #require(result.definition)
            let track = try #require(try candidate.attachments[0].track(
                trackID, as: Int.self, header: HeaderValue.self))
            #expect(track.header.value == 2)
            #expect(result.report.diagnostics.isEmpty)
            #expect(result.report.recordingHealth.isHealthy)
        }
    }
}

private struct RejectedHeader: Error {}

private final class HeaderValue: Sendable {
    let value: Int
    private let onRelease: @Sendable () -> Void

    init(_ value: Int, onRelease: @escaping @Sendable () -> Void = {}) {
        self.value = value
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

private struct HeaderState: Sendable {
    let track: SequentialTrackLease<Int, HeaderValue>
    var version = 0
}

private struct HeaderDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.header-release")
    let values: TrackDefinition<Int, HeaderValue>

    init() throws {
        values = try TrackDefinition("values", header: ValuePreparation<HeaderValue>().admitPrepared(HeaderValue(0)))
    }

    var tracks: [AnyTrackDefinition] {
        [values.erased]
    }

    var record: SystemModeDefinition<HeaderState, SystemExecution<HeaderState>> {
        .init(makeState: { try HeaderState(track: $0.lease(for: values)) }, makeDependency: { $0 })
    }

    var replay: SystemModeDefinition<HeaderState, SystemExecution<HeaderState>> {
        record
    }

    var passthrough: SystemModeDefinition<HeaderState, SystemExecution<HeaderState>> {
        record
    }
}
