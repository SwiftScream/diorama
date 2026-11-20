@testable import DioramaCore
import DioramaHTTP
import HTTPTypes
import Synchronization
import Testing

struct HTTPRecordingFixtures {
    typealias Interaction = HTTPInteraction<String>
    typealias Event = HTTPCaptureEvent<String>

    struct State: Sendable {
        var capture: HTTPRecordingCapture<String>
        let records: HeaderlessSequentialTrackLease<Interaction>
    }

    struct Definition: SystemDefinition {
        let systemType = ScenarioSystemType("capture.http")
        let records = TrackDefinition<Interaction, Void>("interactions")
        let storage: HTTPBodyStoragePolicy
        var tracks: [AnyTrackDefinition] {
            [records.erased]
        }

        var record: SystemModeDefinition<State, SystemExecution<State>> {
            .init(makeState: makeState, makeDependency: { $0 })
        }

        var replay: SystemModeDefinition<State, SystemExecution<State>> {
            record
        }

        var passthrough: SystemModeDefinition<Void, SystemExecution<State>> {
            .init(makeDependency: { _ in throw HTTPRecordingError.incompatibleObservation })
        }

        func makeState(in context: borrowing SystemStateContext) throws -> State {
            try State(capture: .init(storage: storage), records: context.lease(for: records))
        }
    }

    let scenario: ScenarioExecution
    let execution: SystemExecution<State>
    final class Clock: Sendable {
        let instant = Mutex(ContinuousClock.now)
        func advance(_ duration: Duration) {
            instant.withLock { $0 = $0.advanced(by: duration) }
        }
    }

    let clock: Clock

    static func start(storage: HTTPBodyStoragePolicy = .allInline) async throws -> Self {
        let system = try ScenarioSystem(named: "http", definition: Definition(storage: storage))
        let clock = Clock()
        let scenario = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]),
            scenarioID: ScenarioID(rawValue: "capture"), defaultMode: .record, systems: [AnyScenarioSystem(system)],
            clock: ExecutionClock(now: { clock.instant.withLock { $0 } }, sleep: ExecutionClock.continuous().sleep))
        return try Self(scenario: scenario, execution: scenario.dependency(system), clock: clock)
    }

    func begin() throws -> HTTPCaptureOperation {
        try execution.state.withLock { state, operation in
            let lease = state.records
            return try HTTPRecordingCapture.begin(in: &state, at: \State.capture, on: lease,
                                                  resourceStem: { "http/op-\($0.sequence)" }, operation: &operation)
        }
    }

    func reserve(_ handle: HTTPCaptureOperation, attempt: Int = 0) throws -> HTTPCaptureReservation {
        try execution.state.withLock { state, operation in
            try state.capture.reserve(handle, attempt: attempt, operation: &operation)
        }
    }

    func complete(_ token: HTTPCaptureReservation, _ event: Event) throws {
        let value = try ValuePreparation<Event>().admitPrepared(event)
        try execution.state.withLock { state, operation in
            try state.capture.complete(token, with: value, operation: &operation)
        }
    }

    func observe(_ event: Event, on handle: HTTPCaptureOperation, attempt: Int = 0) throws {
        try complete(reserve(handle, attempt: attempt), event)
    }

    func finish(_ handle: HTTPCaptureOperation) async throws -> [Interaction] {
        let result = await scenario.finish()
        let attachment = try #require(result.definition?.attachments.first)
        let candidate = try attachment.track(handle.identity.trackID, as: Interaction.self)
        let track = try #require(candidate)
        return track.records.map(\.value)
    }

    static func request(_ method: HTTPRequest.Method = .get) throws -> HTTPRequestMessage {
        var head = HTTPRequest(method: method, scheme: "https", authority: "example.test", path: "/")
        head.headerFields[.contentLength] = "2"
        return try HTTPRequestMessage(head: head, body: .bytes([0, 255]))
    }

    static func head(_ code: Int = 200, length: String? = "2") -> HTTPResponseHead {
        var head = HTTPResponse(status: .init(code: code))
        head.headerFields[.contentLength] = length
        return HTTPResponseHead(head: head)
    }
}
