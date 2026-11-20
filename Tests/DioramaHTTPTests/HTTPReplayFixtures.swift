@testable import DioramaCore
import DioramaHTTP
import HTTPTypes
import Synchronization
import Testing

struct HTTPReplayFixtures {
    typealias Interaction = HTTPInteraction<String>
    typealias Event = HTTPReplayEvent<String>

    /// Advances only when the scheduler requests a future deadline or the application simulates work.
    final class Clock: Sendable {
        private let origin = ContinuousClock.now
        private let offset = Mutex<Duration>(.zero)
        var now: Duration {
            offset.withLock { $0 }
        }

        func advance(_ duration: Duration) {
            offset.withLock { $0 += duration }
        }

        var source: ExecutionClock {
            ExecutionClock(now: { self.origin.advanced(by: self.now) }, sleep: { deadline, _ in
                try Task.checkCancellation()
                let requested = self.origin.duration(to: deadline)
                self.offset.withLock { $0 = max($0, requested) }
            })
        }
    }

    struct State: Sendable {
        let records: HeaderlessSequentialTrackLease<Interaction>
    }

    struct Definition: SystemDefinition {
        let systemType = ScenarioSystemType("test.http-replay")
        let records: TrackDefinition<Interaction, Void>
        var tracks: [AnyTrackDefinition] {
            [records.erased]
        }

        var record: SystemModeDefinition<Void, HTTPInteractionReplay<String>> {
            .init(makeDependency: { throw HTTPReplayError.inactive })
        }

        var passthrough: SystemModeDefinition<Void, HTTPInteractionReplay<String>> {
            record
        }

        var replay: SystemModeDefinition<State, HTTPInteractionReplay<String>> {
            .init(makeState: { context in try State(records: context.lease(for: records)) },
                  makeDependency: { HTTPInteractionReplay(execution: $0, track: \State.records) },
                  requestStop: { _, replay in await replay?.close() })
        }
    }

    let clock: Clock
    let scenario: ScenarioExecution
    let replay: HTTPInteractionReplay<String>
    let request: PreparedValue<HTTPRequestMessage>

    static func start(_ results: [HTTPAttemptResult<String>]) async throws -> Self {
        let request = try HTTPRecordingFixtures.request()
        let values = try results.map { try ValuePreparation().admitPrepared(Interaction(initialRequest: request,
                                                                                        result: $0)) }
        let system = try ScenarioSystem(named: "http", definition: Definition(records: .init("http", values: values)))
        let clock = Clock()
        let scenario = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]), scenarioID: .init(rawValue: "replay"),
            defaultMode: .replay, systems: [AnyScenarioSystem(system)], clock: clock.source)
        return try Self(clock: clock, scenario: scenario, replay: scenario.dependency(system),
                        request: ValuePreparation().admitPrepared(request))
    }

    static func head(_ code: Int = 200, _ milliseconds: Int64 = 0) throws -> HTTPTimed<HTTPResponseHead> {
        try HTTPTimed(after: delay(milliseconds), value: HTTPRecordingFixtures.head(code))
    }

    static func delay(_ milliseconds: Int64) throws -> HTTPDelay {
        try HTTPDelay(milliseconds: .observed(milliseconds))
    }

    static func challenge() throws -> HTTPAuthenticationChallenge {
        try .init(method: .basic, host: "example.test", port: 443, protocol: "https", realm: nil,
                  isProxy: false, previousFailureCount: 0, proposedCredential: nil)
    }
}
