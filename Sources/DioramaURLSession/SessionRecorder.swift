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

    func observe(_ handle: HTTPCaptureOperation,
                 event: (DiagnosticContext) throws -> HTTPCaptureEvent<URLSessionFailure>)
    {
        _ = try? execution.state.withLockIfOpen { state, operation in
            do {
                let slot = try state.capture.reserve(handle, attempt: 0, operation: &operation)
                let value = try event(.record(handle.identity))
                try state.capture.complete(slot, with: ValuePreparation().admitPrepared(value), operation: &operation)
            } catch {
                state.capture.invalidate(handle, after: error as? PreparationFailure, operation: &operation)
            }
        }
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
