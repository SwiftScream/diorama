import DioramaCore

/// A path contains schema labels and segment positions only. Each decision outcome
/// contributes its own component, including when two branches have identical payload shapes.
struct HTTPTimingPath: Hashable {
    var components: [DiagnosticLabel] = []

    func child(_ name: StaticString) -> Self {
        Self(components: components + [DiagnosticLabel(name)])
    }

    func segment(_ index: Int) -> Self {
        Self(components: components + [DiagnosticLabel("segments"), DiagnosticLabel(index: index)])
    }
}

/// Visits the strict lifecycle in delivery order, rebuilding through its checked constructors.
/// The same traversal identifies baseline authorship and applies it to fresh values.
struct HTTPTimingTraversal<Failure: Sendable> {
    typealias Path = HTTPTimingPath
    typealias Result = HTTPAttemptResult<Failure>
    typealias Body = HTTPBodyDelivery<Failure>
    let delay: (Path, HTTPDelay) -> HTTPDelay

    func timed<Value>(_ value: HTTPTimed<Value>, at path: Path) -> HTTPTimed<Value> {
        HTTPTimed(after: delay(path, value.after), value: value.value)
    }

    func attempt(_ result: Result, at path: Path = Path()) throws -> Result {
        switch result {
        case .openAtRecordingHorizon: return .openAtRecordingHorizon
        case let .failed(value): return .failed(timed(value, at: path.child("failure")))
        case let .received(node):
            let head = timed(node.head, at: path.child("head"))
            let next: HTTPAfterResponseHead<Failure> = switch node.next {
            case let .deliverBody(value): try .deliverBody(body(value, at: path.child("body")))
            case let .redirect(value): try .redirect(redirect(value, at: path.child("redirect")))
            case let .authenticate(value): try .authenticate(authentication(value, at: path.child("authenticate")))
            case let .disposition(value): try .disposition(disposition(value, at: path.child("disposition")))
            }
            return try .received(HTTPResponseNode(head: head, next: next))
        }
    }

    private func body(_ value: Body, at path: Path) throws -> Body {
        let profile = try value.profile.map { profile in
            try HTTPBodyProfile(segments: profile.segments.enumerated().map { index, segment in
                try HTTPBodySegment(byteWeight: segment.byteWeight, after: delay(path.segment(index), segment.after))
            })
        }
        let conclusion: HTTPBodyConclusion<Failure>
        switch value.conclusion {
        case .openAtRecordingHorizon: conclusion = .openAtRecordingHorizon
        case let .failed(value): conclusion = .failed(timed(value, at: path.child("failure")))
        case let .returned(value):
            let trailers = value.trailers.map {
                HTTPTrailers(after: delay(path.child("trailers"), $0.after), fields: $0.fields)
            }
            conclusion = try .returned(HTTPBodyCompletion(after: delay(path.child("completion"), value.after),
                                                          trailers: trailers))
        }
        if let profile {
            return try Body(content: value.content, profile: profile, conclusion: conclusion)
        }
        return Body(content: value.content, conclusion: conclusion)
    }

    private func disposition(_ phase: HTTPResponseDispositionPhase<Failure>, at path: Path) throws
        -> HTTPResponseDispositionPhase<Failure>
    {
        let after = delay(path, phase.after)
        let outcome: HTTPResponseDispositionOutcome<Failure> = switch phase.outcome {
        case .openAtRecordingHorizon: .openAtRecordingHorizon
        case let .allow(value): try .allow(body(value, at: path.child("allow")))
        case let .cancel(value): .cancel(timed(value, at: path.child("cancel")))
        }
        return .init(after: after, outcome: outcome)
    }

    private func redirect(_ phase: HTTPRedirectPhase<Failure>, at path: Path) throws -> HTTPRedirectPhase<Failure> {
        let after = delay(path, phase.after)
        let outcome: HTTPRedirectOutcome<Failure> = switch phase.outcome {
        case .openAtRecordingHorizon: .openAtRecordingHorizon
        case let .refuse(.deliverBody(value)): try .refuse(.deliverBody(body(value, at: path.child("refuse"))))
        case let .refuse(.disposition(value)):
            try .refuse(.disposition(disposition(value, at: path.child("refuse").child("disposition"))))
        case let .followProposed(value): try .followProposed(attempt(value, at: path.child("followProposed")))
        case let .followModified(request, value):
            try .followModified(request, attempt(value, at: path.child("followModified")))
        }
        return .init(after: after, proposedRequest: phase.proposedRequest, outcome: outcome)
    }

    private func authentication(_ phase: HTTPAuthenticationPhase<Failure>, at path: Path) throws
        -> HTTPAuthenticationPhase<Failure>
    {
        let after = delay(path, phase.after)
        let outcome: HTTPAuthenticationOutcome<Failure> = switch phase.outcome {
        case .openAtRecordingHorizon: .openAtRecordingHorizon
        case let .cancel(value): .cancel(timed(value, at: path.child("cancel")))
        case let .useCredential(credential, value):
            try .useCredential(credential, retry(value, at: path.child("useCredential")))
        case let .performDefaultHandling(next):
            try .performDefaultHandling(continuation(next, at: path.child("default")))
        case let .rejectProtectionSpace(next): try .rejectProtectionSpace(continuation(next, at: path.child("reject")))
        }
        return .init(after: after, challenge: phase.challenge, outcome: outcome)
    }

    private func retry(_ value: HTTPAuthenticationRetry<Failure>, at path: Path) throws
        -> HTTPAuthenticationRetry<Failure>
    {
        try .init(request: value.request, result: attempt(value.result, at: path.child("retry")))
    }

    private func continuation(_ next: HTTPAuthenticationContinuation<Failure>, at path: Path) throws
        -> HTTPAuthenticationContinuation<Failure>
    {
        switch next {
        case .openAtRecordingHorizon: .openAtRecordingHorizon
        case let .retry(value): try .retry(retry(value, at: path))
        case let .deliverBody(value): try .deliverBody(body(value, at: path.child("body")))
        case let .failed(value): .failed(timed(value, at: path.child("failure")))
        }
    }
}
