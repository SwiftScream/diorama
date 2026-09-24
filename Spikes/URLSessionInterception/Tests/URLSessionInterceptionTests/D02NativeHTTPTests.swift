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
import Testing

/// The test task alone accepts, reads, and writes this one loopback connection.
/// Foundation runs its ordinary HTTP implementation; no URLProtocol is installed.
final class NativeHTTPServer {
    static let responseStart = "HTTP/1.1 200 OK\r\nContent-Length: 12\r\n" +
        "Content-Type: application/octet-stream\r\nConnection: close\r\n\r\nfirst-"
    let listener: D02LoopbackListener
    private var connection: Int32 = -1
    private var request = Data()

    init() throws {
        listener = try D02LoopbackListener()
    }

    deinit {
        if connection >= 0 {
            close(connection)
        }
    }

    func receiveRequest() -> Bool {
        if connection < 0 {
            connection = accept(listener.descriptor, nil, nil)
            guard connection >= 0 else { return false }
            _ = fcntl(connection, F_SETFL, O_NONBLOCK)
            #if canImport(Darwin)
                var enabled: Int32 = 1
                _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                               socklen_t(MemoryLayout<Int32>.size))
            #endif
        }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = recv(connection, &bytes, bytes.count, 0)
        if count > 0 {
            request.append(contentsOf: bytes.prefix(count))
        }
        return request.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    func requestHeader(_ name: String) -> String? {
        guard let text = String(data: request, encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\r\n").first { line in
            line.lowercased().hasPrefix(name.lowercased() + ":")
        }?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
    }

    /// A short send is reported to the test instead of silently losing bytes.
    func send(_ text: String) -> Bool {
        let data = Data(text.utf8)
        #if canImport(Darwin)
            let flags: Int32 = 0
        #else
            let flags = Int32(MSG_NOSIGNAL)
        #endif
        return data.withUnsafeBytes { bytes in
            #if canImport(Darwin)
                Darwin.send(connection, bytes.baseAddress, bytes.count, flags) == bytes.count
            #else
                Glibc.send(connection, bytes.baseAddress, bytes.count, flags) == bytes.count
            #endif
        }
    }
}

private struct NativeHTTPObservation: Sendable {
    var receivedHead = false
    var chunks: [Data] = []
    var completed = false
    var errorDomain: String?
    var errorCode: Int?
    var decision: (@Sendable (URLSession.ResponseDisposition) -> Void)?

    var body: Data {
        chunks.reduce(into: Data()) { $0.append($1) }
    }
}

private final class NativeHTTPDelegate: NSObject, URLSessionDataDelegate {
    let mode: String
    let observation = Mutex(NativeHTTPObservation())

    init(mode: String) {
        self.mode = mode
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive _: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        switch mode {
        case "cancel": completionHandler(.cancel)
        case "pending": observation.withLock { $0.decision = completionHandler }
        case "taskCancel":
            dataTask.cancel()
            completionHandler(.allow)
        default: completionHandler(.allow)
        }
        observation.withLock { $0.receivedHead = true }
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        observation.withLock { $0.chunks.append(data) }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        observation.withLock {
            $0.errorDomain = (error as NSError?)?.domain
            $0.errorCode = (error as NSError?)?.code
            $0.completed = true
        }
    }

    func allowPendingResponse() {
        let decision = observation.withLock { state in
            defer { state.decision = nil }
            return state.decision
        }
        decision?(.allow)
    }
}

private func nativeSession(delegate: NativeHTTPDelegate) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 3
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
}

private func checkNativeResult(_ result: NativeHTTPObservation, mode: String, sendsSucceeded: Bool) {
    #if canImport(FoundationNetworking)
        let expectsCancellation = mode == "taskCancel"
    #else
        let expectsCancellation = mode == "taskCancel" || mode == "cancel"
    #endif
    print("D02 native \(mode): chunks=\(result.chunks.map(\.count)), " +
        "body=\(String(data: result.body, encoding: .utf8) ?? "invalid UTF-8"), " +
        "error=\(result.errorDomain ?? "nil")/\(result.errorCode ?? 0)")
    if expectsCancellation {
        // Explicit cancellation can race a first chunk already in flight.
        #expect(result.body.isEmpty || (mode == "taskCancel" && result.body == Data("first-".utf8)))
        #expect(result.errorDomain == NSURLErrorDomain)
        #expect(result.errorCode == URLError.cancelled.rawValue)
    } else {
        #expect(sendsSucceeded)
        #expect(result.body == Data("first-second".utf8))
        #expect(result.errorDomain == nil)
    }
}

struct D02NativeHTTPTests {
    @Test(arguments: ["allow", "cancel", "pending", "taskCancel"])
    func `native HTTP disposition and explicit cancellation baseline`(mode: String) async throws {
        let server = try NativeHTTPServer()
        let delegate = NativeHTTPDelegate(mode: mode)
        let session = nativeSession(delegate: delegate)
        defer {
            delegate.allowPendingResponse()
            session.invalidateAndCancel()
        }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.listener.port)/\(mode)"))
        session.dataTask(with: url).resume()
        try #require(await d02Eventually { server.receiveRequest() })
        let firstSent = server.send(NativeHTTPServer.responseStart)
        try #require(firstSent)
        try #require(await d02Eventually { delegate.observation.withLock { $0.receivedHead } })

        // A canceling client may already have closed its socket. Record sends,
        // but only require them for responses expected to consume the body.
        try await Task.sleep(for: .milliseconds(150))
        let secondSent = server.send("second")
        if mode == "pending" {
            try await Task.sleep(for: .milliseconds(150))
            let waiting = delegate.observation.withLock { $0 }
            print("D02 native pending before allow: chunks=\(waiting.chunks.map(\.count)), " +
                "completed=\(waiting.completed)")
            #if canImport(FoundationNetworking)
                #expect(await d02Eventually { delegate.observation.withLock { $0.completed } })
                #expect(delegate.observation.withLock { $0.body } == Data("first-second".utf8))
            #else
                #expect(waiting.body.isEmpty)
                #expect(!waiting.completed)
            #endif
            delegate.allowPendingResponse()
        }
        try #require(await d02Eventually { delegate.observation.withLock { $0.completed } })
        checkNativeResult(delegate.observation.withLock { $0 }, mode: mode,
                          sendsSucceeded: firstSent && secondSent)
    }

    @Test
    func `native HTTP honors a delegate assigned to the task before resume`() async throws {
        let server = try NativeHTTPServer()
        let sessionDelegate = NativeHTTPDelegate(mode: "allow")
        let taskDelegate = NativeHTTPDelegate(mode: "allow")
        let session = nativeSession(delegate: sessionDelegate)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.listener.port)/taskOverride"))
        let task = session.dataTask(with: url)
        task.delegate = taskDelegate
        #expect(task.delegate === taskDelegate)
        task.resume()
        try #require(await d02Eventually { server.receiveRequest() })
        try #require(server.send(NativeHTTPServer.responseStart + "second"))
        try #require(await d02Eventually {
            sessionDelegate.observation.withLock { $0.completed } || taskDelegate.observation.withLock { $0.completed }
        })
        let sessionResult = sessionDelegate.observation.withLock { $0 }
        let taskResult = taskDelegate.observation.withLock { $0 }
        print("D02 native taskOverride: sessionHead=\(sessionResult.receivedHead), " +
            "taskHead=\(taskResult.receivedHead), sessionComplete=\(sessionResult.completed), " +
            "taskComplete=\(taskResult.completed)")
        checkNativeResult(taskResult.completed ? taskResult : sessionResult,
                          mode: "taskOverride", sendsSucceeded: true)
        #expect(!sessionResult.receivedHead)
        #expect(taskResult.receivedHead)
        #expect(taskResult.completed)
    }
}
