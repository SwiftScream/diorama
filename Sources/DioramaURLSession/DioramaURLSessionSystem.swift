import DioramaCore
import DioramaHTTP
import Foundation

#if !os(macOS) && !os(iOS)
    #error("DioramaURLSession supports macOS, iOS, and Mac Catalyst.")
#endif

/// Native URLSession dependencies sharing the version-one interactions schema.
public enum DioramaURLSessionSystem {
    /// Registration for the standard URLSession recording.
    public static let type = URLSessionRecordingSchema.standard.systemType

    /// Copies the configuration at setup. Each execution creates a distinct session.
    /// Instrumented sessions support aggregate HTTP(S) data tasks
    /// with absent or in-memory bodies, using completion handlers or async data APIs.
    /// Record applies the supplied timeouts in the private transport. Replay uses recorded timing.
    /// Replay delivers recorded dependency failures through the native error channel.
    /// Instrumented sessions require nil session and task delegates from the consumer.
    /// All modes gracefully invalidate the session at finish. Already admitted live tasks
    /// can finish, and callers may invalidate a passthrough session themselves.
    public static func instance(named name: String, configuration: URLSessionConfiguration = .default,
                                delegate: any URLSessionDelegate? = nil, delegateQueue: OperationQueue? = nil,
                                matcher: HTTPRequestMatcher = .init(),
                                allowsUnclaimedReplayRecords: Bool = false) throws -> ScenarioSystem<URLSession>
    {
        guard let copy = configuration.copy() as? URLSessionConfiguration else {
            throw SessionBridgeError.configuration
        }
        return try ScenarioSystem(named: name, definition: SessionDefinition(
            configuration: copy, delegate: delegate, delegateQueue: delegateQueue, matcher: matcher,
            interactions: URLSessionRecordingSchema.interactions(matching: matcher)),
        allowsUnclaimedReplayRecords: allowsUnclaimedReplayRecords)
    }
}

enum SessionBridgeError: Error {
    case configuration, unsupported, ownership, conversion
}

struct SessionDefinition: SystemDefinition {
    typealias Interaction = HTTPInteraction<URLSessionFailure>
    let configuration: URLSessionConfiguration
    let delegate: any URLSessionDelegate?
    let delegateQueue: OperationQueue?
    let matcher: HTTPRequestMatcher
    let interactions: TrackDefinition<Interaction, Void>
    let systemType = DioramaURLSessionSystem.type

    var tracks: [AnyTrackDefinition] {
        [interactions.erased]
    }

    func validate(in context: borrowing SystemValidationContext) throws {
        guard context.mode != .passthrough else { return }
        let attachment = context.attachmentID
        try context.validate(interactions) { _ in
            guard configuration.identifier == nil, delegate == nil, delegateQueue == nil else {
                throw SessionBridgeError.configuration
            }
        } diagnosticForFailure: { _ in
            Diagnostic(issue: .system(DiagnosticLabel("urlsession.unsupported-configuration")),
                       context: .attachment(attachment))
        }
        try URLSessionRecordingSchema.standard.validate(in: context) { capability in
            switch capability {
            case .requestMethod, .requestBody, .responseBody, .failure, .openHorizon: true
            default: false
            }
        }
    }

    var passthrough: SystemModeDefinition<Void, URLSession> {
        .init(
            makeDependency: { URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: delegateQueue) },
            requestStop: { _, session in session?.finishTasksAndInvalidate() })
    }

    var record: SystemModeDefinition<SessionRecordState, URLSession> {
        .init(
            makeState: { try SessionRecordState(track: $0.lease(for: interactions)) },
            makeDependency: { execution in
                let (owner, track) = try execution.state.withLock { state, _ in (state.owner, state.track.id) }
                return try owner.activate(configuration, reporter: execution.reporter, track: track) { forwarding in
                    .record(SessionRecorder(execution: execution), SessionForwarding(configuration: forwarding))
                }
            },
            requestStop: { context, session in
                if let owner = try? context.state.withLock({ $0.owner }) {
                    await owner.stop(session)
                }
            })
    }

    var replay: SystemModeDefinition<SessionReplayState, URLSession> {
        .init(
            makeState: { try SessionReplayState(track: $0.lease(for: interactions)) },
            makeDependency: { execution in
                let (owner, track) = try execution.state.withLock { state, _ in (state.owner, state.track.id) }
                let replay = HTTPInteractionReplay(
                    execution: execution,
                    track: \SessionReplayState.track,
                    matcher: matcher)
                return try owner.activate(configuration, reporter: execution.reporter, track: track) { _ in
                    .replay(replay)
                }
            },
            requestStop: { context, session in
                if let owner = try? context.state.withLock({ $0.owner }) {
                    await owner.stop(session)
                }
            },
            cleanUp: { context, session in
                if let session, let owner = try? context.state.withLock({ $0.owner }) {
                    await owner.drain(session)
                }
                return .completed
            })
    }
}
