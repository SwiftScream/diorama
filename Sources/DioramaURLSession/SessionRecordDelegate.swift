import DioramaCore
import DioramaHTTP
import Foundation
import Synchronization

enum SessionDataDelegate {
    static func supported(_ delegate: any URLSessionDelegate?) -> (any URLSessionDataDelegate)? {
        guard let data = delegate as? any URLSessionDataDelegate else { return nil }
        typealias TaskDelegate = URLSessionTaskDelegate
        let unsupported = [
            #selector(URLSessionTaskDelegate.urlSession(_:task:needNewBodyStream:)),
            #selector(URLSessionDataDelegate.urlSession(_:dataTask:willCacheResponse:completionHandler:)),
            #selector(URLSessionTaskDelegate.urlSession(_:task:willBeginDelayedRequest:completionHandler:)),
            #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:)),
            #selector(URLSessionTaskDelegate.urlSession(_:task:didReceive:completionHandler:)),
            #selector(TaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)),
        ]
        return unsupported.contains(where: { data.responds(to: $0) }) ? nil : data
    }
}

/// Transport bytes may precede the outer response callback, even the entire body
/// for short text. At presentation the consumer's callbacks become authoritative.
final class SessionRecordDelegate: NSObject, URLSessionDataDelegate {
    private struct Observation: Sendable {
        weak var recorder: SessionRecorder?
        let handle: HTTPCaptureOperation
    }

    private enum Phase {
        case transport, pending(RecordDispositionReply), allowed, receivedData
        case canceled, unsupported, stopped
    }

    private struct State: Sendable {
        var observation: Observation?
        var phase = Phase.transport
    }

    private let state = Mutex(State())
    private let cancellation = Mutex<NSKeyValueObservation?>(nil)
    private let consumer: any URLSessionDataDelegate
    private struct NativeTask: Sendable { weak var value: URLSessionDataTask? }
    private let native: NativeTask
    var task: URLSessionDataTask? {
        native.value
    }

    init(consumer: any URLSessionDataDelegate, task: URLSessionDataTask) {
        self.consumer = consumer
        native = NativeTask(value: task)
    }

    var observesDisposition: Bool {
        consumer.responds(to: #selector(URLSessionDataDelegate.urlSession(_:dataTask:didReceive:completionHandler:)))
    }

    func bind(_ recorder: SessionRecorder, handle: HTTPCaptureOperation) {
        state.withLock { $0.observation = Observation(recorder: recorder, handle: handle) }
    }

    func observeTransport(_ observation: () -> Void) {
        state.withLock {
            if case .transport = $0.phase {
                observation()
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        guard observesDisposition else { completionHandler(.allow); return }
        let reply = RecordDispositionReply(completionHandler)
        state.withLock { state in
            state.phase = .pending(reply)
            if let item = state.observation {
                item.recorder?.observe(item.handle, head: .resume) { _ in .disposition }
            }
        }
        let token = dataTask.observe(\.state, options: [.initial]) { [weak self] task, _ in
            if task.state == .canceling {
                self?.taskCanceled()
            }
        }
        cancellation.withLock { $0 = token }
        consumer.urlSession?(session, dataTask: dataTask, didReceive: response) { [weak self] choice in
            reply.resolve { self?.answer(choice) ?? choice }
        }
    }

    private func taskCanceled() {
        let pending: RecordDispositionReply? = state.withLock { state in
            switch state.phase {
            case let .pending(reply):
                state.phase = .stopped
                return reply
            case .allowed, .receivedData: state.phase = .stopped
            default: break
            }
            return nil
        }
        // Leave the native state notification before disposing a held reply.
        if let pending {
            Task { pending.resolve { .cancel } }
        }
    }

    private func answer(_ choice: URLSession.ResponseDisposition) -> URLSession.ResponseDisposition {
        state.withLock { state in
            guard case .pending = state.phase else { return .cancel }
            guard let decision = try? HTTPResponseDispositionDecision(urlSessionDisposition: choice) else {
                state.phase = .unsupported
                if let item = state.observation {
                    item.recorder?.reject(item.handle, reason: "urlsession.unsupported-disposition")
                }
                return .cancel
            }
            state.phase = decision == .allow ? .allowed : .canceled
            if let item = state.observation {
                item.recorder?.observe(item.handle) { _ in .dispositionAnswer(decision) }
            }
            return choice
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.withLock { state in
            switch state.phase {
            case .allowed, .receivedData: break
            default: return
            }
            state.phase = .receivedData
            if let item = state.observation {
                item.recorder?.observe(item.handle) { _ in .segment(Array(data)) }
            }
        }
        consumer.urlSession?(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: any Error?) {
        let token = cancellation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        token?.invalidate()
        let result: any Error? = state.withLock { state in
            defer { state.observation = nil; state.phase = .stopped }
            if case .unsupported = state.phase {
                return SessionBridgeError.unsupported
            }
            guard let item = state.observation, let recorder = item.recorder else { return error }
            switch state.phase {
            case .allowed:
                if error == nil {
                    recorder.observe(item.handle) { _ in .content(.bytes([])) }
                }
            case .receivedData, .canceled: break
            default: return error
            }
            recorder.complete(item.handle, error: error)
            return error
        }
        consumer.urlSession?(session, task: task, didCompleteWithError: result)
    }
}

/// The live answer survives scenario finish. Explicit task cancellation still
/// releases Foundation's held completion even when the consumer never answers.
private final class RecordDispositionReply: Sendable {
    typealias Reply = @Sendable (URLSession.ResponseDisposition) -> Void
    private let native: Mutex<Reply?>

    init(_ reply: @escaping Reply) {
        native = Mutex(reply)
    }

    func resolve(_ choice: () -> URLSession.ResponseDisposition) {
        let reply = native.withLock { stored in
            defer { stored = nil }
            return stored
        }
        guard let reply else { return }
        reply(choice())
    }
}
