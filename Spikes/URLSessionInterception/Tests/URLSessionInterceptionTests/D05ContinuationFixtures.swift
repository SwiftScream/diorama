import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization

private struct D05LiveContinuationState: Sendable {
    var tail: D05WeakObject<D05ForwardTail>?
    var following = false
    var finished = false
    var body: Data?
}

/// A native operation outlives the execution and individual redirect protocol
/// instances. The session delegate owns admitted operations until completion;
/// the global lookup is weak and is removed at termination. No execution lives
/// here: only the detached observation gate, native task and forwarding context.
final class D05LiveOperation: Sendable {
    private let nativeTask: D05WeakObject<URLSessionTask>
    private let identifier: ObjectIdentifier
    var task: URLSessionTask? {
        nativeTask.value
    }

    let setup: D05ForwardSetup
    let sender = Mutex<D04Sender?>(nil)
    private let owner: D05WeakObject<D05NativeObserver>
    private let state: Mutex<D05LiveContinuationState>

    init(task: URLSessionTask, setup: D05ForwardSetup, owner: D05NativeObserver) {
        nativeTask = D05WeakObject(task)
        identifier = ObjectIdentifier(task)
        self.setup = setup
        self.owner = D05WeakObject(owner)
        state = Mutex(D05LiveContinuationState(body: task.originalRequest?.httpBody))
    }

    func attach(_ tail: D05ForwardTail, request: URLRequest) -> URLRequest {
        state.withLock {
            $0.tail = D05WeakObject(tail)
            $0.following = false
            var prepared = request
            if request.httpBodyStream != nil {
                prepared.httpBodyStream = nil
                prepared.httpBody = $0.body
            }
            return prepared
        }
    }

    func isCurrent(_ tail: D05ForwardTail) -> Bool {
        state.withLock { !$0.following && !$0.finished && $0.tail?.value === tail }
    }

    func prepareRedirect(_ request: URLRequest?) {
        guard let request else { return }
        state.withLock { $0.following = true; $0.body = request.httpBody }
    }

    func refuseRedirect() {
        state.withLock { $0.tail?.value }?.refuseRedirect()
    }

    /// This fixture admits one live operation per session. Production must key
    /// decision admission and disposal per task so cancellation stays local.
    func abortDecisions() {
        owner.value?.closeDecisionAdmission()
    }

    func finish() {
        let first = state.withLock { state in
            defer { state.finished = true; state.tail = nil }
            return !state.finished
        }
        guard first else { return }
        sender.withLock { $0 = nil }
        let key = identifier
        D05ForwardProtocol.continuations.withLock { $0[key] = nil }
        let owner = owner.value
        owner?.liveOperations.withLock { $0[key] = nil }
    }
}
