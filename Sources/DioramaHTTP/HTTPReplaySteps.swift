import DioramaCore

/// Work up to and including the next decision or leaf. Branches are expanded only after selection.
struct HTTPReplayStep<Failure: Sendable>: Sendable {
    enum Action: Sendable {
        case emit(HTTPReplayEvent<Failure>)
        case decision(HTTPReplayBarrier<Failure>)
    }

    let delay: Int64
    let action: Action

    static func attempt(_ result: HTTPAttemptResult<Failure>, request: HTTPRequestMessage) throws -> [Self] {
        switch result {
        case .openAtRecordingHorizon: return []
        case let .failed(failure): return [failed(failure)]
        case let .received(response):
            let head = Self(delay: response.head.after.milliseconds.value,
                            action: .emit(.response(response.head.value, request: request)))
            let continuation: [Self] = switch response.next {
            case let .deliverBody(value): try body(value)
            case let .redirect(phase):
                [.init(delay: phase.after.milliseconds.value, action: .decision(.redirect(phase)))]
            case let .authenticate(phase):
                [.init(delay: phase.after.milliseconds.value, action: .decision(.auth(phase, request)))]
            case let .disposition(phase): [.disposition(phase)]
            }
            return [head] + continuation
        }
    }

    static func disposition(_ phase: HTTPResponseDispositionPhase<Failure>) -> Self {
        Self(delay: phase.after.milliseconds.value, action: .decision(.disposition(phase)))
    }

    static func authentication(_ continuation: HTTPAuthenticationContinuation<Failure>,
                               request: HTTPRequestMessage) throws -> [Self]
    {
        switch continuation {
        case let .retry(retry): try attempt(retry.result, request: retry.effectiveRequest(inheriting: request))
        case let .deliverBody(value): try body(value)
        case let .failed(failure): [failed(failure)]
        case .openAtRecordingHorizon: []
        }
    }

    static func failed(_ failure: HTTPTimed<Failure>) -> Self {
        Self(delay: failure.after.milliseconds.value, action: .emit(.failed(failure.value)))
    }

    static func body(_ value: HTTPBodyDelivery<Failure>) throws -> [Self] {
        var steps: [Self] = []
        let bytes: [UInt8]? = switch value.content {
        case let .bytes(bytes): bytes
        case let .resource(resource): resource.bytes()
        case .absent, .unavailable: nil
        }
        if let bytes, let profile = value.profile {
            steps = try profile.allocate(byteCount: bytes.count).map {
                Self(delay: $0.after.milliseconds.value, action: .emit(.bytes(bytes[$0.byteRange])))
            }
        } else if let bytes {
            steps.append(Self(delay: 0, action: .emit(.bytes(bytes[...]))))
        }
        switch value.conclusion {
        case .openAtRecordingHorizon: break
        case let .failed(failure): steps.append(failed(failure))
        case let .returned(completion):
            if let trailers = completion.trailers {
                steps.append(Self(delay: trailers.after.milliseconds.value, action: .emit(.trailers(trailers.fields))))
            }
            steps.append(Self(delay: completion.after.milliseconds.value, action: .emit(.returned)))
        }
        return steps
    }
}

enum HTTPReplayDecision: Sendable {
    case redirect(HTTPRedirectDecision)
    case auth(HTTPAuthenticationDecision)
    case disposition(HTTPResponseDispositionDecision)
}

enum HTTPReplayBarrier<Failure: Sendable>: Sendable {
    case redirect(HTTPRedirectPhase<Failure>)
    case auth(HTTPAuthenticationPhase<Failure>, HTTPRequestMessage)
    case disposition(HTTPResponseDispositionPhase<Failure>)

    var isHorizon: Bool {
        switch self {
        case let .redirect(phase):
            if case .openAtRecordingHorizon = phase.outcome {
                return true
            }
        case let .auth(phase, _):
            if case .openAtRecordingHorizon = phase.outcome {
                return true
            }
        case let .disposition(phase):
            if case .openAtRecordingHorizon = phase.outcome {
                return true
            }
        }
        return false
    }

    func select(_ answer: HTTPReplayDecision, matcher: HTTPRequestMatcher) throws -> [HTTPReplayStep<Failure>] {
        typealias Step = HTTPReplayStep<Failure>
        if isHorizon {
            throw HTTPReplayError.decisionBeyondRecordingHorizon
        }
        switch (self, answer) {
        case let (.redirect(phase), .redirect(decision)):
            switch try phase.continuation(for: decision, requestsMatch: {
                matcher.matches(matcher.projectOwned($0), matcher.projectOwned($1))
            }) {
            case let .attempt(request, result): return try Step.attempt(result, request: request)
            case let .deliverBody(body): return try Step.body(body)
            case let .disposition(phase): return [Step.disposition(phase)]
            }
        case let (.auth(phase, request), .auth(decision)):
            return try Step.authentication(phase.continuation(for: decision), request: request)
        case let (.disposition(phase), .disposition(decision)):
            switch try phase.continuation(for: decision) {
            case let .deliverBody(body): return try Step.body(body)
            case let .failed(failure): return [Step.failed(failure)]
            }
        default: throw HTTPReplayError.incompatibleDecision
        }
    }
}
