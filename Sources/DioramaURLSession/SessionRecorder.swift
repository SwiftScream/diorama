import DioramaCore
import DioramaHTTP
import Foundation
import HTTPTypesFoundation

struct SessionRecordState: Sendable {
    let track: HeaderlessSequentialTrackLease<SessionDefinition.Interaction>
    let owner = SessionOwner()
    var capture = HTTPRecordingCapture<URLSessionFailure>()
}

struct SessionReplayState: Sendable {
    let track: HeaderlessSequentialTrackLease<SessionDefinition.Interaction>
    let owner = SessionOwner()
}

struct SessionResponse {
    let native: URLResponse
    let time: Result<LogicalTimeCapture, ExecutionTimeFailure>?
    var body: Data?
}

enum SessionResult {
    case returned(SessionResponse)
    case failed(any Error, partial: SessionResponse?)
}

enum SessionMessage {
    static func request(_ native: URLRequest) throws -> HTTPRequestMessage {
        guard var head = native.httpRequest else { throw SessionBridgeError.conversion }
        head.headerFields = ordered(head.headerFields)
        let body: HTTPRequestBody = native.httpBody.map { .bytes(Array($0)) } ?? .absent
        return try HTTPRequestMessage(head: head, body: body)
    }

    static func response(_ native: URLResponse) throws -> HTTPResponseHead {
        guard var head = (native as? HTTPURLResponse)?.httpResponse else { throw SessionBridgeError.conversion }
        head.headerFields = ordered(head.headerFields)
        return HTTPResponseHead(head: head)
    }

    /// Foundation exposes a dictionary at this boundary. Stabilize independent
    /// names and retain the relative order of any values sharing a name.
    private static func ordered(_ fields: HTTPFields) -> HTTPFields {
        var ordered = HTTPFields()
        for field in fields.sorted(by: { $0.name.canonicalName < $1.name.canonicalName }) {
            ordered.append(field)
        }
        return ordered
    }
}

final class SessionRecorder: Sendable {
    let execution: SystemExecution<SessionRecordState>

    init(execution: SystemExecution<SessionRecordState>) {
        self.execution = execution
    }

    private static func resourceStem(_ identity: RecordIdentity) -> String {
        let key = identity.trackID.attachmentID.key.rawValue.utf8.map { String(format: "%02x", $0) }.joined()
        return "urlsession-\(key)-\(identity.sequence)"
    }

    func begin(_ native: URLRequest) throws -> HTTPCaptureOperation? {
        try execution.state.withLock { state, operation in
            let handle = try HTTPRecordingCapture.begin(in: &state, at: \SessionRecordState.capture,
                                                        on: state.track, resourceStem: Self.resourceStem,
                                                        operation: &operation)
            do {
                let context = DiagnosticContext.record(handle.identity)
                let request = try HTTPPreparation().request(reporter: execution.reporter, context: context)
                    .prepare(capturing: { try SessionMessage.request(native) }, purpose: .recording,
                             reporter: execution.reporter, context: context)
                let event: HTTPCaptureEvent<URLSessionFailure> = .request(request.value)
                try state.capture.complete(handle.initial, with: ValuePreparation().admitPrepared(event),
                                           operation: &operation)
                return handle
            } catch {
                state.capture.invalidate(handle, after: error as? PreparationFailure, operation: &operation)
                return nil
            }
        }
    }

    func responseTime() -> Result<LogicalTimeCapture, ExecutionTimeFailure>? {
        let result = try? execution.state.withLockIfOpen { _, operation in
            Result { () throws(ExecutionTimeFailure) in try operation.time.capture() }
        }
        guard case let .performed(time) = result else { return nil }
        return time
    }

    /// An aggregate observation commits at native completion. The head's
    /// capture keeps its timing anchor even when the body ends in failure.
    func complete(_ result: SessionResult, handle: HTTPCaptureOperation) -> URLResponse? {
        let (response, error): (SessionResponse?, any Error?) = switch result {
        case let .returned(response): (response, nil)
        case let .failed(error, partial): (partial, error)
        }
        var delivered = response?.native
        _ = try? execution.state.withLockIfOpen { state, operation in
            do {
                let completedAt = try operation.time.capture()
                let head = try response.map {
                    try state.capture.reserve(handle, attempt: 0, observedAt: $0.time?.get(), operation: &operation)
                }
                let content = try response?.body.map { _ in
                    try state.capture.reserve(handle, attempt: 0, observedAt: completedAt, operation: &operation)
                }
                let end = try state.capture.reserve(
                    handle, attempt: 0, observedAt: completedAt, operation: &operation)
                let context = DiagnosticContext.record(handle.identity)
                let events = ValuePreparation<HTTPCaptureEvent<URLSessionFailure>>()
                if let head, let response {
                    let value = try HTTPPreparation().response(reporter: execution.reporter, context: context)
                        .prepare(capturing: { try SessionMessage.response(response.native) }, purpose: .recording,
                                 reporter: execution.reporter, context: context)
                    try state.capture.complete(head, with: events.admitPrepared(.response(value.value)),
                                               operation: &operation)
                    if error == nil {
                        guard let url = response.native.url, let native = HTTPURLResponse(
                            httpResponse: value.value.head, url: url)
                        else { throw SessionBridgeError.conversion }
                        delivered = native
                    }
                }
                if let body = response?.body, let content {
                    let bytes = try events.admitPrepared(.content(.bytes(Array(body))))
                    try state.capture.complete(content, with: bytes, operation: &operation)
                }
                let terminal: HTTPCaptureEvent<URLSessionFailure>
                if let error {
                    let captured = try URLSessionFailure.captureForRecording(
                        error, reporter: execution.reporter, context: context)
                    terminal = .failed(captured.value)
                } else {
                    terminal = .returned
                }
                try state.capture.complete(end, with: events.admitPrepared(terminal), operation: &operation)
            } catch {
                state.capture.invalidate(handle, after: error as? PreparationFailure, operation: &operation)
                delivered = response?.native
            }
        }
        return delivered
    }

    func reject(_ handle: HTTPCaptureOperation, reason: StaticString) {
        _ = try? execution.state.withLockIfOpen { _, operation in
            operation.report(Diagnostic(
                issue: .system(DiagnosticLabel(reason)),
                context: .record(handle.identity),
                recordingImpact: .invalidatesCandidate))
        }
    }
}
