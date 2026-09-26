import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif
import Synchronization

enum D02TaskKind: String, CaseIterable, Sendable {
    case data
    case uploadData
    case uploadStream
    case download
    case webSocket
    #if canImport(Darwin)
        case stream
    #endif
}

func d02Kind(of task: URLSessionTask?) -> String {
    guard let task else { return "missing" }
    if task is URLSessionWebSocketTask {
        return "webSocket"
    }
    if task is URLSessionUploadTask {
        return "upload"
    }
    if task is URLSessionDownloadTask {
        return "download"
    }
    #if canImport(Darwin)
        if task is URLSessionStreamTask {
            return "stream"
        }
    #endif
    return task is URLSessionDataTask ? "data" : "other"
}

struct D02RejectionState: Sendable {
    var requestChecks = 0
    var taskChecks = 0
    var starts: [String] = []
    var bodyStreams: [Bool] = []
}

final class D02RejectingProtocol: URLProtocol {
    static let observations = Mutex(D02RejectionState())
    static let errorDomain = "DioramaD02Unsupported"
    static let markerKey = "DioramaD02Rejection"

    override static func canInit(with _: URLRequest) -> Bool {
        observations.withLock { $0.requestChecks += 1 }
        return true
    }

    override static func canInit(with _: URLSessionTask) -> Bool {
        observations.withLock { $0.taskChecks += 1 }
        return true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.observations.withLock {
            $0.starts.append(d02Kind(of: task))
            $0.bodyStreams.append(request.httpBodyStream != nil)
        }
        let error = NSError(domain: Self.errorDomain, code: 1, userInfo: [Self.markerKey: true])
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {}
}

struct D02TaskOutcome: Sendable {
    var createdKinds: [String] = []
    var completed = false
    var errorDomain: String?
    var errorCode: Int?
    var hasRejectionMarker = false
    var bodyStreamRequests = 0
    var operationCompleted = false
    var operationErrorDomain: String?
    var operationErrorCode: Int?
}

final class D02TaskDelegate: NSObject, URLSessionTaskDelegate {
    let outcome = Mutex(D02TaskOutcome())
    let cancelOnCreation: Bool

    init(cancelOnCreation: Bool = false) {
        self.cancelOnCreation = cancelOnCreation
    }

    /// FoundationNetworking 6.4 has no corresponding protocol requirement.
    /// Declaring this method there lets the same observation show its absence.
    func urlSession(_: URLSession, didCreateTask task: URLSessionTask) {
        outcome.withLock { $0.createdKinds.append(d02Kind(of: task)) }
        if cancelOnCreation {
            task.cancel()
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        outcome.withLock {
            $0.completed = true
            $0.errorDomain = (error as NSError?)?.domain
            $0.errorCode = (error as NSError?)?.code
            $0.hasRejectionMarker = (error as NSError?)?.userInfo[D02RejectingProtocol.markerKey] as? Bool == true
        }
    }

    func completeOperation(error: (any Error)?) {
        outcome.withLock {
            $0.operationCompleted = true
            $0.operationErrorDomain = (error as NSError?)?.domain
            $0.operationErrorCode = (error as NSError?)?.code
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask,
                    needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void)
    {
        outcome.withLock { $0.bodyStreamRequests += 1 }
        completionHandler(InputStream(data: Data("stream".utf8)))
    }
}

func d02RejectingSession(delegate: D02TaskDelegate) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [D02RejectingProtocol.self]
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = d02WatchdogSeconds
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
}

func d02Task(kind: D02TaskKind, session: URLSession, port: Int) -> URLSessionTask {
    let url = URL(string: "http://127.0.0.1:\(port)/d02")!
    switch kind {
    case .data:
        return session.dataTask(with: url)
    case .uploadData:
        return session.uploadTask(with: URLRequest(url: url), from: Data("body".utf8))
    case .uploadStream:
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        return session.uploadTask(withStreamedRequest: request)
    case .download:
        return session.downloadTask(with: url)
    case .webSocket:
        return session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/d02")!)
    #if canImport(Darwin)
        case .stream:
            return session.streamTask(withHostName: "127.0.0.1", port: port)
    #endif
    }
}

/// Start the native operation without waiting so the test can poll for a connection.
func d02StartOperation(_ task: URLSessionTask, delegate: D02TaskDelegate) {
    if let webSocket = task as? URLSessionWebSocketTask {
        webSocket.receive { result in
            switch result {
            case .success: delegate.completeOperation(error: nil)
            case let .failure(error): delegate.completeOperation(error: error)
            }
        }
    }
    #if canImport(Darwin)
        if let stream = task as? URLSessionStreamTask {
            stream.write(Data("probe".utf8), timeout: 1) { delegate.completeOperation(error: $0) }
        }
    #endif
}

/// A deadlock watchdog, not a response-timing requirement. Hosted simulator
/// callback scheduling can exceed three seconds while the native result is valid.
let d02WatchdogSeconds: TimeInterval = 30

func d02Eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(d02WatchdogSeconds))
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// A nonblocking loopback listener whose accepted sockets are immediately closed.
/// The test owns and polls it; no background thread or remote endpoint is used.
final class D02LoopbackListener {
    let descriptor: Int32
    let port: Int
    private(set) var connections = 0

    init() throws {
        #if canImport(Darwin)
            let socketType = SOCK_STREAM
        #else
            let socketType = Int32(SOCK_STREAM.rawValue)
        #endif
        let descriptor = socket(AF_INET, socketType, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        guard bound == 0, listen(descriptor, 8) == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            close(descriptor)
            throw POSIXError(.EIO)
        }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else {
            close(descriptor)
            throw POSIXError(.EIO)
        }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit { close(descriptor) }

    @discardableResult
    func poll() -> Bool {
        let connection = accept(descriptor, nil, nil)
        guard connection >= 0 else { return false }
        connections += 1
        close(connection)
        return true
    }
}
