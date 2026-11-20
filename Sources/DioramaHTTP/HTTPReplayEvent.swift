import DioramaCore
import HTTPTypes

/// One reached HTTP delivery. A decision callback may be retained and answered later.
/// Return from the presentation hook once handed off, including for unanswered decisions.
public enum HTTPReplayEvent<Failure: Sendable>: Sendable {
    /// The current attempt received this prepared head.
    case response(HTTPResponseHead, request: HTTPRequestMessage)
    /// Bytes exposed by one effective segment, including an observed empty segment.
    case bytes(ArraySlice<UInt8>)
    /// Successful delivery exposed trailer fields.
    case trailers(HTTPFields)
    /// The recorded operation returned.
    case returned
    /// The recorded dependency failed.
    case failed(Failure)
    /// Replay stopped before the next scheduled handoff. The adapter should complete the operation with this error.
    case infrastructureFailure(HTTPReplayError)
    /// Present the prepared redirect proposal and submit the current prepared choice.
    case redirect(HTTPRequestMessage, HTTPReplayAnswer<HTTPRedirectDecision>)
    /// Present the recorded challenge and submit the current prepared choice.
    case authenticate(HTTPAuthenticationChallenge, HTTPReplayAnswer<HTTPAuthenticationDecision>)
    /// Ask the consumer whether to allow body delivery.
    case disposition(HTTPReplayAnswer<HTTPResponseDispositionDecision>)
}

/// A decision is usable once, only at its own presentation in its originating operation.
public struct HTTPReplayAnswer<Decision: Sendable>: Sendable {
    let submit: @Sendable (PreparedValue<Decision>) async throws -> Void

    /// Continues the claimed record from the current answer's time.
    public func callAsFunction(_ decision: PreparedValue<Decision>) async throws {
        try await submit(decision)
    }
}

/// Control for a single claimed interaction. Cancellation preserves its claim and observed progress.
public struct HTTPReplayOperation: Sendable {
    /// Stable identity of the claimed interaction.
    public let identity: RecordIdentity
    let stop: @Sendable () async -> Void

    /// Stops future delivery. A delivery already handed off can finish and acknowledge its progress.
    public func cancel() async {
        await stop()
    }
}

/// Infrastructure outcomes distinct from a recorded HTTP dependency failure.
public enum HTTPReplayError: Error, Equatable {
    /// The operation has stopped or this presentation has already been answered.
    case inactive
    /// The current prepared answer cannot select the recorded continuation.
    case incompatibleDecision
    /// The application answered a decision that was unanswered at the recording horizon.
    case decisionBeyondRecordingHorizon
    /// The next delivery could not be scheduled after a recorded handoff.
    case schedulingFailed
}
