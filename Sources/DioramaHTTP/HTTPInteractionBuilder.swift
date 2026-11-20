import DioramaCore
import HTTPTypes

/// The current leaf and the observed edges leading to it. Only compatible events can advance a leaf.
struct HTTPInteractionBuilder<Failure: Sendable>: Sendable {
    typealias Result = HTTPAttemptResult<Failure>
    typealias Body = HTTPBodyDelivery<Failure>
    typealias Next = HTTPAfterResponseHead<Failure>
    typealias Edge = @Sendable (Result) throws -> Result
    typealias BodyEdge = @Sendable (Body) throws -> Result
    typealias AuthEdge = @Sendable (HTTPAuthenticationContinuation<Failure>) throws -> Result
    typealias RefusalEdge = @Sendable (HTTPRedirectRefusal<Failure>) throws -> Result
    typealias DispositionEdge = @Sendable (HTTPResponseDispositionOutcome<Failure>) throws -> Result

    struct Response: Sendable {
        let head: HTTPTimed<HTTPResponseHead>
        let method: HTTPRequest.Method

        func finish(_ next: Next) throws -> Result {
            let node = try HTTPResponseNode(head: head, next: next)
            return try .received(HTTPContentLength.response(
                ValuePreparation().admitPrepared(node), requestMethod: method))
        }
    }

    enum Phase: Sendable {
        case root, attempt
        case head(Response)
        case redirect(Response, HTTPDelay, HTTPRequestMessage)
        case refused(Response, RefusalEdge)
        case challenge(Response, HTTPDelay, HTTPAuthenticationChallenge)
        case disposition(Response, DispositionEdge)
        case nativeHandling(Response, AuthEdge)
        case canceled(@Sendable (HTTPTimed<Failure>) throws -> Result)
        case body(Response, BodyEdge)
        case ended(Result)
    }

    let stem: String
    let storage: HTTPBodyStoragePolicy
    var phase = Phase.root
    var initial: HTTPRequestMessage?
    var method = HTTPRequest.Method.get
    var attempt = 0
    var previous: Int64 = 0
    var edges: [Edge] = []
    var body = HTTPCapturedBody()

    var isAwaitingCompletion: Bool {
        if case .canceled = phase {
            return true
        }
        return body.trailers != nil
    }

    mutating func observe(_ event: HTTPCaptureEvent<Failure>, attempt observedAttempt: Int, time: Int64) throws {
        guard observedAttempt == attempt else { throw HTTPRecordingError.wrongAttempt }
        guard time >= previous else { throw HTTPRecordingError.invalidTime }
        let delay = try HTTPDelay(milliseconds: .observed(time - previous))
        switch event {
        case let .request(value):
            guard case .root = phase else { throw HTTPRecordingError.incompatibleObservation }
            let request = try select(value, suffix: "request")
            initial = request
            method = request.head.method
            phase = .attempt
        case let .response(head):
            guard case .attempt = phase else { throw HTTPRecordingError.incompatibleObservation }
            phase = .head(Response(head: HTTPTimed(after: delay, value: head), method: method))
        case .redirect, .challenge:
            try present(event, delay: delay)
        case .disposition:
            try presentDisposition(delay: delay)
        default:
            guard try observeContinuation(event, delay: delay) else { return }
        }
        previous = time
    }

    private mutating func present(_ event: HTTPCaptureEvent<Failure>, delay: HTTPDelay) throws {
        guard case let .head(response) = phase else { throw HTTPRecordingError.incompatibleObservation }
        switch event {
        case let .redirect(proposal):
            phase = try .redirect(response, delay, select(proposal, suffix: "proposal"))
        case let .challenge(value):
            guard response.head.value.head.status.code == (value.isProxy ? 407 : 401) else {
                throw HTTPRecordingError.incompatibleObservation
            }
            phase = .challenge(response, delay, value)
        default: throw HTTPRecordingError.incompatibleObservation
        }
    }

    private mutating func presentDisposition(delay: HTTPDelay) throws {
        switch phase {
        case let .head(response):
            phase = .disposition(response) { try response.finish(.disposition(.init(after: delay, outcome: $0))) }
        case let .refused(response, edge):
            phase = .disposition(response) { try edge(.disposition(.init(after: delay, outcome: $0))) }
        default:
            throw HTTPRecordingError.incompatibleObservation
        }
    }

    private mutating func observeContinuation(_ event: HTTPCaptureEvent<Failure>, delay: HTTPDelay) throws -> Bool {
        switch event {
        case let .redirectAnswer(answer): try answerRedirect(answer)
        case let .challengeAnswer(answer): try answerChallenge(answer)
        case let .dispositionAnswer(answer): try answerDisposition(answer)
        case let .retry(changed):
            guard case let .nativeHandling(_, edge) = phase else { throw HTTPRecordingError.incompatibleObservation }
            try retry(changed) { try edge(.retry($0)) }
            return false // Keep the decision as the retry's timing anchor.
        default:
            return try observeBody(event, delay: delay)
        }
        return true
    }

    func select(_ value: HTTPRequestMessage, suffix: String) throws -> HTTPRequestMessage {
        let selected = try storage.request(ValuePreparation().admitPrepared(value),
                                           resourceStem: resourceStem(suffix))
        return try HTTPContentLength.request(ValuePreparation().admitPrepared(selected))
    }

    func resourceStem(_ suffix: String) -> String {
        "\(stem)-\(attempt)-\(suffix)"
    }

    func freeze() throws -> HTTPInteraction<Failure> {
        guard let initial else { throw HTTPRecordingError.incompatibleObservation }
        let result = try edges.reversed().reduce(leaf()) { try $1($0) }
        return try HTTPInteraction(initialRequest: initial, result: result)
    }

    private func leaf() throws -> Result {
        switch phase {
        case .root, .canceled: throw HTTPRecordingError.incompatibleObservation
        case .attempt: .openAtRecordingHorizon
        case let .ended(result): result
        case let .redirect(response, delay, proposal):
            try response.finish(.redirect(.init(after: delay, proposedRequest: proposal,
                                                outcome: .openAtRecordingHorizon)))
        case let .challenge(response, delay, challenge):
            try response.finish(.authenticate(.init(after: delay, challenge: challenge,
                                                    outcome: .openAtRecordingHorizon)))
        case let .disposition(_, edge): try edge(.openAtRecordingHorizon)
        case let .nativeHandling(_, edge): try edge(.openAtRecordingHorizon)
        case .body, .head, .refused: try conclude(.openAtRecordingHorizon)
        }
    }
}

extension HTTPInteractionBuilder {
    mutating func advance(request: HTTPRequestMessage?, edge: @escaping Edge) {
        edges.append(edge)
        if let request {
            method = request.head.method
        }
        attempt += 1
        phase = .attempt
    }

    mutating func answerRedirect(_ answer: HTTPCapturedRedirectAnswer) throws {
        guard case let .redirect(response, after, proposed) = phase else {
            throw HTTPRecordingError.incompatibleObservation
        }
        @Sendable func finish(_ outcome: HTTPRedirectOutcome<Failure>) throws -> Result {
            try response.finish(.redirect(.init(after: after, proposedRequest: proposed, outcome: outcome)))
        }
        switch answer {
        case .refuse: phase = .refused(response) { try finish(.refuse($0)) }
        case .followProposed: advance(request: proposed) { try finish(.followProposed($0)) }
        case let .followModified(value):
            let request = try select(value, suffix: "modified")
            advance(request: request) { try finish(.followModified(request, $0)) }
        }
    }

    mutating func answerChallenge(_ answer: HTTPCapturedAuthenticationAnswer) throws {
        guard case let .challenge(response, after, challenge) = phase else {
            throw HTTPRecordingError.incompatibleObservation
        }
        @Sendable func finish(_ outcome: HTTPAuthenticationOutcome<Failure>) throws -> Result {
            try response.finish(.authenticate(.init(after: after, challenge: challenge, outcome: outcome)))
        }
        switch answer {
        case let .useCredential(credential, changed):
            try retry(changed) { try finish(.useCredential(credential, $0)) }
        case .cancel: phase = .canceled { try finish(.cancel($0)) }
        case .performDefaultHandling: phase = .nativeHandling(response) { try finish(.performDefaultHandling($0)) }
        case .rejectProtectionSpace: phase = .nativeHandling(response) { try finish(.rejectProtectionSpace($0)) }
        }
    }

    mutating func retry(_ changed: HTTPRequestMessage?,
                        finish: @escaping @Sendable (HTTPAuthenticationRetry<Failure>) throws -> Result) throws
    {
        let request = try changed.map { try select($0, suffix: "retry") }
        advance(request: request) { try finish(.init(request: request, result: $0)) }
    }

    mutating func answerDisposition(_ answer: HTTPResponseDispositionDecision) throws {
        guard case let .disposition(response, finish) = phase else { throw HTTPRecordingError.incompatibleObservation }
        switch answer {
        case .allow: phase = .body(response) { try finish(.allow($0)) }
        case .cancel: phase = .canceled { try finish(.cancel($0)) }
        }
    }
}
