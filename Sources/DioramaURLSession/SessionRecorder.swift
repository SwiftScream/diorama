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

enum SessionMessage {
    static func request(_ native: URLRequest) throws -> HTTPRequestMessage {
        guard var head = native.httpRequest else { throw SessionBridgeError.conversion }
        head.headerFields = ordered(head.headerFields)
        return try HTTPRequestMessage(head: head)
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

    /// The private completion-handler task observes one native result. Reserve
    /// every part at that callback, before converting its head or copying bytes.
    func complete(_ native: URLResponse, data: Data?, handle: HTTPCaptureOperation) -> URLResponse {
        var delivered = native
        _ = try? execution.state.withLockIfOpen { state, operation in
            do {
                let head = try state.capture.reserve(handle, attempt: 0, operation: &operation)
                let content = try data.map { _ in try state.capture.reserve(
                    handle,
                    attempt: 0,
                    operation: &operation) }
                let end = try state.capture.reserve(handle, attempt: 0, operation: &operation)
                let context = DiagnosticContext.record(handle.identity)
                let value = try HTTPPreparation().response(reporter: execution.reporter, context: context)
                    .prepare(capturing: { try SessionMessage.response(native) }, purpose: .recording,
                             reporter: execution.reporter, context: context)
                guard let url = native.url, let response = HTTPURLResponse(
                    httpResponse: value.value.head,
                    url: url)
                else { throw SessionBridgeError.conversion }
                let events = ValuePreparation<HTTPCaptureEvent<URLSessionFailure>>()
                try state.capture.complete(
                    head,
                    with: events.admitPrepared(.response(value.value)),
                    operation: &operation)
                if let data, let content {
                    let bytes = try events.admitPrepared(.content(.bytes(Array(data))))
                    try state.capture.complete(content, with: bytes, operation: &operation)
                }
                try state.capture.complete(end, with: events.admitPrepared(.returned), operation: &operation)
                delivered = response
            } catch {
                state.capture.invalidate(handle, after: error as? PreparationFailure, operation: &operation)
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
