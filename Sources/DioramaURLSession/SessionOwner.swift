import DioramaCore
import DioramaHTTP
import Foundation
import Synchronization

enum SessionMode: Sendable {
    case record(SessionRecorder)
    case replay(HTTPInteractionReplay<URLSessionFailure>)
}

/// One outer session lease. The serial executor orders admission and shutdown
/// and never creates private tasks on Foundation's URLProtocol callback queue.
final class SessionOwner: NSObject, URLSessionTaskDelegate {
    private struct Services: Sendable {
        let mode: SessionMode
        let reporter: DiagnosticReporter
        let track: TrackID
        let forwarding: URLSessionConfiguration

        func reject(_ label: StaticString) {
            let impact: RecordingImpact = if case .record = mode {
                .invalidatesCandidate
            } else {
                .none
            }
            reporter.record(Diagnostic(
                issue: .system(DiagnosticLabel(label)),
                context: .attachment(track.attachmentID),
                recordingImpact: impact))
        }
    }

    enum TaskStatus { case created, admitted }

    private struct Weak<Value: AnyObject & Sendable>: Sendable { weak var value: Value? }

    private enum Pending: Sendable {
        case created(Weak<URLSessionTask>)
        case admitted(Weak<SessionDelivery>)

        var task: URLSessionTask? {
            switch self {
            case let .created(ref): ref.value
            case let .admitted(ref): ref.value?.task
            }
        }
    }

    private let work = DispatchQueue(label: "DioramaURLSession.forwarding")
    private let services = Mutex<Services?>(nil)
    private let tasks = Mutex<[ObjectIdentifier: Pending]>([:])
    private let replayStarts = Mutex<Task<Void, Never>?>(nil)
    private let lookupTail = Mutex<Task<Void, Never>?>(nil)
    private let invalidation = AsyncStream<Void>.makeStream()

    func activate(_ configuration: URLSessionConfiguration, mode: SessionMode,
                  reporter: DiagnosticReporter, track: TrackID) throws -> URLSession
    {
        guard let outer = configuration.copy() as? URLSessionConfiguration,
              let forwarding = configuration.copy() as? URLSessionConfiguration
        else {
            throw SessionBridgeError.configuration
        }
        let protocols = (outer.protocolClasses ?? []).filter { $0 != SessionProtocol.self }
        for copy in [outer, forwarding] {
            copy.urlCache = nil
            copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        }
        outer.protocolClasses = [SessionProtocol.self] + protocols
        forwarding.protocolClasses = protocols
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: outer, delegate: self, delegateQueue: delegateQueue)
        services
            .withLock { $0 = Services(mode: mode, reporter: reporter, track: track, forwarding: forwarding) }
        SessionRoutes.entries.withLock { $0.append(.init(session: session, owner: self)) }
        return session
    }

    func urlSession(_: URLSession, didCreateTask task: URLSessionTask) {
        if task is URLSessionWebSocketTask || task is URLSessionStreamTask {
            task.cancel()
            services.withLock { $0 }?.reject("urlsession.unsupported-task")
            return
        }
        // Keep attachment-level diagnostic attribution available when ownership
        // lookup itself fails. A supplied delegate stays visible for rejection.
        if task.delegate == nil {
            task.delegate = self
        }
        tasks.withLock { state in
            state = state.filter { $0.value.task != nil }
            state[ObjectIdentifier(task)] = .created(Weak(value: task))
        }
    }

    func urlSession(_: URLSession, didBecomeInvalidWithError _: any Error?) {
        invalidation.continuation.finish()
    }

    func status(of task: URLSessionTask) -> TaskStatus? {
        tasks.withLock { entries in
            guard let entry = entries[ObjectIdentifier(task)], entry.task === task else { return nil }
            switch entry {
            case .created: return .created
            case .admitted: return .admitted
            }
        }
    }

    /// The creation hook identifies a candidate session. Confirm membership in
    /// Foundation's outstanding tasks before admitting anything. Queue these
    /// confirmations in protocol-entry order within each session so a later
    /// lookup cannot take an earlier equivalent request's replay record.
    func resolve(
        _ task: URLSessionTask,
        in session: URLSession,
        completion: @escaping @Sendable (SessionOwner?) -> Void)
    {
        lookupTail.withLock { tail in
            let previous = tail
            tail = Task {
                await previous?.value
                let outstanding = await session.allTasks
                completion(outstanding.contains { $0 === task } ? self : nil)
            }
        }
    }

    func rejectOwnership() {
        services.withLock { $0 }?.reject("urlsession.invalid-ownership")
    }

    func start(_ delivery: SessionDelivery, request: URLRequest) {
        work.async { [self] in
            guard let services = services.withLock({ $0 }) else {
                delivery.finish(SessionBridgeError.ownership)
                return
            }
            delivery.whileOpen {
                guard let task = delivery.task, let original = task.originalRequest,
                      task is URLSessionDataTask, !(task is URLSessionUploadTask),
                      task.delegate == nil || task.delegate === self,
                      original.httpMethod == "GET", original.httpBody == nil, original.httpBodyStream == nil,
                      ["http", "https"].contains(request.url?.scheme?.lowercased())
                else {
                    services.reject("urlsession.unsupported-task")
                    delivery.finish(SessionBridgeError.unsupported)
                    return
                }
                let admitted = tasks.withLock { state in
                    let key = ObjectIdentifier(task)
                    guard case let .created(ref) = state[key], ref.value === task else { return false }
                    state[key] = .admitted(Weak(value: delivery))
                    return true
                }
                guard admitted else {
                    rejectOwnership()
                    delivery.finish(SessionBridgeError.ownership)
                    return
                }
                load(delivery, request: request, services: services)
            }
        }
    }

    private func load(_ delivery: SessionDelivery, request: URLRequest, services: Services) {
        do {
            switch services.mode {
            case let .record(recorder):
                let handle = try recorder.begin(request)
                let forwarding = SessionForwarding(recorder: recorder, handle: handle, delivery: delivery)
                let configuration = services.forwarding
                work.async { [work] in forwarding.start(request, configuration: configuration, executor: work) }
            case let .replay(replay):
                let context = DiagnosticContext.track(services.track)
                let value = try HTTPPreparation().request(reporter: services.reporter, context: context)
                    .prepare(capturing: { try SessionMessage.request(request) }, purpose: .replay,
                             reporter: services.reporter, context: context)
                replayStarts.withLock { tail in
                    let previous = tail
                    tail = Task {
                        await previous?.value
                        await Self.startReplay(replay, request: value, delivery: delivery)
                    }
                }
            }
        } catch { delivery.finish(error) }
    }

    private static func startReplay(_ replay: isolated HTTPInteractionReplay<URLSessionFailure>,
                                    request: PreparedValue<HTTPRequestMessage>, delivery: SessionDelivery)
    {
        do {
            try delivery.whileOpen {
                let operation = try replay.start(matching: request) { event in delivery.deliver(event) }
                delivery.onCancel { Task { await operation.cancel() } }
            }
        } catch { delivery.finish(error) }
    }

    func stop(_ session: URLSession?) async {
        guard let session else { return }
        let mode: SessionMode? = await withCheckedContinuation { continuation in
            work.async { [self] in
                let mode = services.withLock { value in
                    defer { value = nil }
                    return value?.mode
                }
                SessionRoutes.entries.withLock { $0.removeAll { $0.owner === self } }
                let pending = tasks.withLock { state in
                    defer { state.removeAll() }
                    return state.values
                }
                for entry in pending {
                    switch entry {
                    case let .created(ref): ref.value?.cancel()
                    case let .admitted(ref):
                        if case .replay = mode, let delivery = ref.value,
                           delivery.stop()
                        {
                            delivery.task?.cancel()
                        }
                    }
                }
                session.finishTasksAndInvalidate()
                continuation.resume(returning: mode)
            }
        }
        if case let .replay(controller) = mode {
            await controller.close()
        }
    }

    func drain(_ session: URLSession) async {
        await lookupTail.withLock { $0 }?.value
        await replayStarts.withLock { $0 }?.value
        for await _ in invalidation.stream {}
        await withCheckedContinuation { continuation in
            session.delegateQueue.addBarrierBlock { continuation.resume() }
        }
    }
}
