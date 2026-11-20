import HTTPTypes

/// One stable observation for incremental recording. Prepare payloads before completing their reservation.
public enum HTTPCaptureEvent<Failure: Sendable>: Sendable {
    /// Root request at invocation. Complete the initial reservation with this event.
    case request(HTTPRequestMessage)
    /// Received head for the current attempt.
    case response(HTTPResponseHead)
    /// Present a redirect proposal under its observed head.
    case redirect(HTTPRequestMessage)
    /// Complete the current redirect decision, distinguishing an actual modification explicitly.
    case redirectAnswer(HTTPCapturedRedirectAnswer)
    /// Present the prepared challenge under its owning response.
    case challenge(HTTPAuthenticationChallenge)
    /// Answer the current challenge and begin its decision-relative timing.
    case challengeAnswer(HTTPCapturedAuthenticationAnswer)
    /// Default/reject handling observed a retry. Nil inherits the effective request.
    case retry(HTTPRequestMessage?)
    /// Present a consumer-visible response disposition.
    case disposition
    /// Answer the current disposition.
    case dispositionAnswer(HTTPResponseDispositionDecision)
    /// Append one observed delivery, including its timing and any zero-byte segment.
    case segment([UInt8])
    /// Body content observed without chunk callbacks. Terminal timing retains the preceding anchor.
    case content(HTTPResponseBody)
    /// Trailers belonging to a subsequently observed successful conclusion.
    case trailers(HTTPFields)
    /// Complete body delivery successfully.
    case returned
    /// Record one prepared dependency failure at the current phase.
    case failed(Failure)
}

/// The effective request on a redirect edge. Modified requests carry their full prepared value.
public enum HTTPCapturedRedirectAnswer: Sendable {
    /// Follow the recorded proposal unchanged.
    case followProposed
    /// Follow a materially different request.
    case followModified(HTTPRequestMessage)
    /// Expose the existing response, including any observed response disposition.
    case refuse
}

/// An observed challenge answer with only the metadata required by its branch.
public enum HTTPCapturedAuthenticationAnswer: Sendable {
    /// Retry using safe credential metadata and an optional material request change.
    case useCredential(HTTPAuthenticationCredential, request: HTTPRequestMessage?)
    /// Native default handling determines the following observation.
    case performDefaultHandling
    /// Native rejection determines the following observation.
    case rejectProtectionSpace
    /// Await the resulting dependency failure.
    case cancel
}
