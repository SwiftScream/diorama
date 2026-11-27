import DioramaCore
import DioramaHTTP
import Foundation
import Synchronization

/// One native task and its application delegate. Foundation chooses whether the
/// response callback runs. The scheduler owns the application-visible continuation.
final class SessionReplayDelegate: NSObject, URLSessionDataDelegate {
    typealias NativeReply = @Sendable (URLSession.ResponseDisposition) -> Void
    typealias Answer = HTTPReplayAnswer<HTTPResponseDispositionDecision>

    private struct Requirement: Sendable {
        let record: RecordIdentity
        let phase: HTTPResponseDispositionPhase<URLSessionFailure>
    }

    private struct Received: Sendable {
        let required: Requirement
        let head: HTTPResponseHead
        let request: HTTPRequestMessage
    }

    private struct Presentation: Sendable {
        let record: RecordIdentity
        let reply: NativeReply
        let cancelBranch: Bool
    }

    private enum State: Sendable {
        case ordinary
        case expected(Requirement)
        case received(Received)
        case waiting(Requirement, Answer)
        case presented(Presentation, Answer)
        case answered(Presentation)
        case completing(any Error?)
        case closed
    }

    private let state = Mutex(State.ordinary)
    private let completed: @Sendable (SessionReplayDelegate) -> Void
    private let consumer: any URLSessionDataDelegate
    private let reporter: DiagnosticReporter
    private struct NativeTask: Sendable {
        weak var session: URLSession?
        weak var task: URLSessionDataTask?
    }

    private let native: NativeTask

    init(consumer: any URLSessionDataDelegate, reporter: DiagnosticReporter,
         session: URLSession, task: URLSessionDataTask, completed: @escaping @Sendable (SessionReplayDelegate) -> Void)
    {
        self.completed = completed
        self.consumer = consumer
        self.reporter = reporter
        native = NativeTask(session: session, task: task)
    }

    var canPresentResponseDecision: Bool {
        consumer.responds(to: #selector(URLSessionDataDelegate.urlSession(_:dataTask:didReceive:completionHandler:)))
    }

    func expect(_ record: RecordIdentity, phase: HTTPResponseDispositionPhase<URLSessionFailure>) {
        state.withLock {
            if case .ordinary = $0 {
                $0 = .expected(.init(record: record, phase: phase))
            }
        }
    }

    private let cancellation = Mutex<NSKeyValueObservation?>(nil)
    private let operation = Mutex<HTTPReplayOperation?>(nil)

    func owns(_ task: URLSessionTask) -> Bool {
        native.task === task
    }

    func bind(_ operation: HTTPReplayOperation) {
        self.operation.withLock { $0 = operation }
    }

    func deliver(_ event: HTTPReplayEvent<URLSessionFailure>, to delivery: SessionDelivery) async {
        switch event {
        case let .response(head, request):
            let held = state.withLock {
                guard case let .expected(required) = $0 else { return false }
                $0 = .received(.init(required: required, head: head, request: request))
                return true
            }
            if !held {
                delivery.deliver(event)
            }
        case let .disposition(answer):
            prime(delivery, answer: answer)
        case let .bytes(data) where hasAnswered:
            await deliverBytes(Data(data))
        case .returned where hasAnswered: resolve(nil)
        case let .failed(failure) where hasAnswered:
            let error = failure.makeError()
            resolve(error)
        case let .infrastructureFailure(error) where hasAnswered: resolve(error)
        default: delivery.deliver(event)
        }
    }

    private func deliverBytes(_ data: Data) async {
        guard let session = native.session, let task = native.task else { return }
        await withCheckedContinuation { done in
            session.delegateQueue.addOperation { [self] in
                if hasAnswered, task.state != .canceling, task.state != .completed {
                    consumer.urlSession?(session, dataTask: task, didReceive: data)
                }
                done.resume()
            }
        }
    }

    private func prime(_ delivery: SessionDelivery, answer: Answer) {
        let input: Received? = state.withLock {
            guard case let .received(input) = $0 else { return nil }
            $0 = .waiting(input.required, answer)
            return input
        }
        guard let input else { return }
        let required = input.required
        delivery.deliver(.response(input.head, request: input.request))
        switch required.phase.body?.content {
        case let .bytes(bytes): delivery.bytes(Data(bytes))
        case let .resource(resource): delivery.bytes(Data(resource.bytes()))
        default: break
        }
        // Foundation may buffer a text head until its input ends. Its native
        // disposition continuation gates the matched task's actual completion.
        if case let .failed(failure) = required.phase.body?.conclusion {
            delivery.finish(failure.value.makeError())
        } else {
            delivery.finish()
        }
    }

    private var hasAnswered: Bool {
        state.withLock {
            if case .answered = $0 {
                true
            } else {
                false
            }
        }
    }

    private func resolve(_ error: any Error?, incompatible: Bool = false) {
        let presentation: Presentation? = state.withLock {
            guard case let .answered(presentation) = $0 else { return nil }
            $0 = .completing(error)
            return presentation
        }
        if let presentation {
            presentation.reply(incompatible || presentation.cancelBranch ? .cancel : .allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping NativeReply)
    {
        let present = state.withLock {
            guard case let .waiting(required, answer) = $0 else { return false }
            let canceled = if case .cancel = required.phase.outcome {
                true
            } else {
                false
            }
            $0 = .presented(.init(record: required.record, reply: completionHandler, cancelBranch: canceled), answer)
            answer.acknowledgePresentation()
            return true
        }
        guard present else {
            let ordinary = state.withLock {
                if case .ordinary = $0 {
                    true
                } else {
                    false
                }
            }
            completionHandler(ordinary ? .allow : .cancel)
            return
        }
        // Protocol EOF can precede the application's answer, so stopLoading
        // alone cannot release a native continuation on explicit task cancellation.
        let observation = dataTask.observe(\.state, options: [.initial]) { [weak self] task, _ in
            if task.state == .canceling {
                Task { self?.close() }
            }
        }
        cancellation.withLock { $0 = observation }
        consumer.urlSession?(session, dataTask: dataTask, didReceive: response) { [weak self] choice in
            self?.answer(choice)
        }
    }

    private func answer(_ choice: URLSession.ResponseDisposition) {
        let answer: Answer? = state.withLock {
            guard case let .presented(presentation, answer) = $0 else { return nil }
            $0 = .answered(presentation)
            return answer
        }
        guard let answer else { return }
        Task {
            do {
                let value = try HTTPResponseDispositionDecision(urlSessionDisposition: choice)
                try await answer(ValuePreparation().admitPrepared(value))
            } catch {
                if error is HTTPResponseDispositionError {
                    state.withLock {
                        if case let .answered(presentation) = $0 {
                            let issue = DiagnosticIssue.system(DiagnosticLabel("urlsession.unsupported-disposition"))
                            reporter.record(Diagnostic(issue: issue, context: .record(presentation.record)))
                        }
                    }
                }
                resolve(error, incompatible: true)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if state.withLock({
            if case .ordinary = $0 {
                true
            } else {
                false
            }
        }) {
            consumer.urlSession?(session, dataTask: dataTask, didReceive: data)
        }
    }

    private func reportMissing(_ required: Requirement) {
        reporter.record(Diagnostic(issue: .system(DiagnosticLabel("urlsession.response-decision-not-presented")),
                                   context: .record(required.record)))
    }

    /// Metrics also arrive for completion handlers and async APIs, which bypass
    /// the data delegate's terminal callback. Finish checks the same state.
    func urlSession(_: URLSession, task _: URLSessionTask, didFinishCollecting _: URLSessionTaskMetrics) {
        close()
        completed(self)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: any Error?) {
        close()
        let result: any Error? = state.withLock {
            defer { $0 = .closed }
            if case let .completing(recorded) = $0 {
                return recorded ?? error
            }
            return error
        }
        completed(self)
        consumer.urlSession?(session, task: task, didCompleteWithError: result)
    }

    /// Close an outstanding reply once. Real native completion can race shutdown.
    func close() {
        let (abandoned, reply): (Bool, NativeReply?) = state.withLock {
            switch $0 {
            case let .waiting(required, _):
                reportMissing(required)
            case let .presented(presentation, _), let .answered(presentation):
                $0 = .closed
                return (true, presentation.reply)
            case .completing, .closed, .ordinary: return (false, nil)
            case .expected, .received: break
            }
            $0 = .closed
            return (true, nil)
        }
        if abandoned, let control = operation.withLock({ $0 }) {
            Task { await control.cancel() }
        }
        let observation = cancellation.withLock { value in
            defer { value = nil }
            return value
        }
        observation?.invalidate()
        if let reply {
            if let task = native.task, task.state != .canceling {
                task.cancel()
            }
            reply(.cancel)
        }
    }
}
