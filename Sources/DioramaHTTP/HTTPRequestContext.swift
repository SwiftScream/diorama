import HTTPTypes

private enum RequestContextKey: String, CodingKey {
    case response, head, value, fields, next, redirect, authenticate, outcome, continuation, retry, result
}

extension HTTPAttemptResult {
    func validateRequestMethod(_ method: HTTPRequest.Method, codingPath: [any CodingKey]? = nil) throws {
        guard case let .received(response) = self else { return }
        if response.head.value.derivesContentLength, !HTTPContentLength.unambiguous(method: method) {
            if let codingPath {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: codingPath + [
                        RequestContextKey.response, RequestContextKey.head,
                        RequestContextKey.value, RequestContextKey.fields,
                    ],
                    debugDescription: "Derived HTTP response length conflicts with its effective request method"))
            }
            throw HTTPMessageError.invalidField
        }
        switch response.next {
        case let .redirect(phase): try phase.validateRequestMethod(codingPath: codingPath)
        case let .authenticate(phase): try phase.validateRequestMethod(method, codingPath: codingPath)
        case .deliverBody, .disposition: break
        }
    }
}

private extension HTTPRedirectPhase {
    func validateRequestMethod(codingPath: [any CodingKey]?) throws {
        let path = codingPath.map {
            $0 + [
                RequestContextKey.response, RequestContextKey.next, RequestContextKey.redirect,
                RequestContextKey.outcome, RequestContextKey.result,
            ]
        }
        switch outcome {
        case let .followProposed(result):
            try result.validateRequestMethod(proposedRequest.head.method, codingPath: path)
        case let .followModified(request, result):
            try result.validateRequestMethod(request.head.method, codingPath: path)
        case .refuse, .openAtRecordingHorizon: break
        }
    }
}

private extension HTTPAuthenticationPhase {
    func validateRequestMethod(_ method: HTTPRequest.Method, codingPath: [any CodingKey]?) throws {
        let base = codingPath.map {
            $0 + [
                RequestContextKey.response, RequestContextKey.next,
                RequestContextKey.authenticate, RequestContextKey.outcome,
            ]
        }
        let retry: HTTPAuthenticationRetry<Failure>
        let path: [any CodingKey]?
        switch outcome {
        case let .useCredential(_, next):
            retry = next
            path = base.map { $0 + [RequestContextKey.retry, RequestContextKey.result] }
        case let .performDefaultHandling(.retry(next)), let .rejectProtectionSpace(.retry(next)):
            retry = next
            path = base.map {
                $0 + [RequestContextKey.continuation, RequestContextKey.retry, RequestContextKey.result]
            }
        default: return
        }
        try retry.result.validateRequestMethod(retry.request?.head.method ?? method, codingPath: path)
    }
}
