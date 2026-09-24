import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization
import Testing

private final class ExtendedRejectingProtocol: URLProtocol {
    static let starts = Mutex<[String]>([])

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canInit(with _: URLSessionTask) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.starts.withLock { $0.append(d02Kind(of: task)) }
        client?.urlProtocol(self, didFailWithError: NSError(domain: D02RejectingProtocol.errorDomain, code: 1))
    }

    override func stopLoading() {}
}

private func extendedRejectionSession(_ delegate: D02TaskDelegate) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ExtendedRejectingProtocol.self]
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 3
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
}

private final class ResumeCapture: Sendable {
    let value = Mutex<(completed: Bool, data: Data?)>((false, nil))
}

#if canImport(Darwin)
    private final class UploadResumeObserver: NSObject, URLSessionTaskDelegate {
        let acknowledged = Mutex(false)

        func urlSession(_: URLSession, task _: URLSessionTask,
                        didReceiveInformationalResponse response: HTTPURLResponse)
        {
            if response.statusCode == 104 {
                acknowledged.withLock { $0 = true }
            }
        }
    }

    /// Keep callback capture synchronous so the test can bound its wait.
    private func cancelForResume(_ task: URLSessionDownloadTask) -> ResumeCapture {
        let capture = ResumeCapture()
        task.cancel { data in
            capture.value.withLock {
                $0.data = data
                $0.completed = true
            }
        }
        return capture
    }

    private func cancelUploadForResume(_ task: URLSessionUploadTask) -> ResumeCapture {
        let capture = ResumeCapture()
        task.cancel { data in
            capture.value.withLock {
                $0.data = data
                $0.completed = true
            }
        }
        return capture
    }

    private func nativeUploadResumeData(server: NativeHTTPServer, file: URL) async throws -> Data {
        let observer = UploadResumeObserver()
        let session = URLSession(configuration: .ephemeral, delegate: observer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.listener.port)/upload"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let task = session.uploadTask(with: request, fromFile: file)
        task.resume()
        try #require(await d02Eventually { server.receiveRequest() })
        let version = try #require(server.requestHeader("Upload-Draft-Interop-Version"))
        print("D02 upload resume source: interop=\(version)")
        // The fixture only advertises resumption and captures native resume data;
        // it does not implement a production resumable-upload server.
        try #require(server.send("HTTP/1.1 104 Upload Resumption Supported\r\n" +
                "Upload-Draft-Interop-Version: \(version)\r\n" +
                "Location: http://127.0.0.1:\(server.listener.port)/upload/resource\r\n\r\n"))
        try #require(await d02Eventually { observer.acknowledged.withLock { $0 } })
        let capture = cancelUploadForResume(task)
        try #require(await d02Eventually { capture.value.withLock { $0.completed } })
        return try #require(capture.value.withLock { $0.data })
    }

    private func nativeResumeData(server: NativeHTTPServer) async throws -> Data {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.listener.port)/resume"))
        let task = session.downloadTask(with: url)
        task.resume()
        try #require(await d02Eventually { server.receiveRequest() })
        try #require(server.send("HTTP/1.1 200 OK\r\nContent-Length: 65536\r\n" +
                "Content-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\n" +
                "ETag: \"d02-resume\"\r\nConnection: close\r\n\r\n" + String(repeating: "x", count: 32768)))
        let received = await d02Eventually { task.countOfBytesReceived >= 1024 }
        print("D02 resume source: bytes=\(task.countOfBytesReceived), state=\(task.state.rawValue), " +
            "status=\((task.response as? HTTPURLResponse)?.statusCode ?? 0)")
        try #require(received)
        let capture = cancelForResume(task)
        try #require(await d02Eventually { capture.value.withLock { $0.completed } })
        return try #require(capture.value.withLock { $0.data })
    }
#endif

@Suite(.serialized)
struct D02ExtendedRejectionTests {
    @Test(arguments: ["fileUpload", "dataUpload", "downloadRequest", "downloadURL"], [false, true])
    func `async excluded factories throw before connection`(kind: String, suppliedDelegate: Bool) async throws {
        ExtendedRejectingProtocol.starts.withLock { $0 = [] }
        let listener = try D02LoopbackListener()
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/async"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file-body".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let observer = D02TaskDelegate()
        let session = extendedRejectionSession(observer)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = kind.hasSuffix("Upload") ? "POST" : "GET"
        var failure: NSError?
        do {
            try await runAsyncExcluded(kind, session: session, request: request, file: file,
                                       delegate: suppliedDelegate ? observer : nil)
            Issue.record("An excluded async operation unexpectedly succeeded")
        } catch {
            failure = error as NSError
        }
        listener.poll()
        #expect(failure?.domain == D02RejectingProtocol.errorDomain)
        #expect(ExtendedRejectingProtocol.starts.withLock { $0 } == [kind.hasSuffix("Upload") ? "upload" : "download"])
        #expect(listener.connections == 0)
        print("D02 async rejection \(kind)/delegate=\(suppliedDelegate): error=\(failure?.domain ?? "nil")")
    }

    @Test(arguments: ["fileUpload", "dataUpload", "downloadRequest", "downloadURL"], [false, true])
    func `remaining task factories reject before connection`(kind: String, completion: Bool) async throws {
        ExtendedRejectingProtocol.starts.withLock { $0 = [] }
        let listener = try D02LoopbackListener()
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/factory"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file-body".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let delegate = D02TaskDelegate()
        let session = extendedRejectionSession(delegate)
        defer { session.invalidateAndCancel() }
        let task = makeExcludedTask(kind, completion: completion, session: session, delegate: delegate,
                                    locations: (url, file))
        task.resume()
        try #require(await d02Eventually { delegate.outcome.withLock { $0.completed || $0.operationCompleted } })
        listener.poll()
        let outcome = delegate.outcome.withLock { $0 }
        let domain = completion ? outcome.operationErrorDomain : outcome.errorDomain
        let starts = ExtendedRejectingProtocol.starts.withLock { $0 }
        print("D02 factory \(kind)/\(completion): starts=\(starts), error=\(domain ?? "nil"), " +
            "connections=\(listener.connections)")
        #expect(starts == [kind.hasSuffix("Upload") ? "upload" : "download"])
        #expect(domain == D02RejectingProtocol.errorDomain)
        #expect(listener.connections == 0)
    }

    @Test(arguments: ["ftp", "file", "https"])
    func `additional schemes enter the custom protocol`(scheme: String) async throws {
        ExtendedRejectingProtocol.starts.withLock { $0 = [] }
        let listener = try D02LoopbackListener()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file-body".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let url = try scheme == "file" ? file : #require(URL(string: "\(scheme)://127.0.0.1:\(listener.port)/scheme"))
        let delegate = D02TaskDelegate()
        let session = extendedRejectionSession(delegate)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: url).resume()
        try #require(await d02Eventually { delegate.outcome.withLock { $0.completed } })
        listener.poll()
        let starts = ExtendedRejectingProtocol.starts.withLock { $0 }
        let outcome = delegate.outcome.withLock { $0 }
        print("D02 scheme \(scheme): starts=\(starts), error=\(outcome.errorDomain ?? "nil"), " +
            "connections=\(listener.connections)")
        #expect(starts == ["data"])
        #expect(outcome.errorDomain == D02RejectingProtocol.errorDomain)
        #expect(listener.connections == 0)
    }

    #if canImport(Darwin)
        @Test(arguments: [false, true])
        func `async download resume throws before another connection`(suppliedDelegate: Bool) async throws {
            ExtendedRejectingProtocol.starts.withLock { $0 = [] }
            let server = try NativeHTTPServer()
            let resumeData = try await nativeResumeData(server: server)
            let observer = D02TaskDelegate()
            let session = extendedRejectionSession(observer)
            defer { session.invalidateAndCancel() }
            var failure: NSError?
            do {
                let (file, _) = try await session.download(resumeFrom: resumeData,
                                                           delegate: suppliedDelegate ? observer : nil)
                try? FileManager.default.removeItem(at: file)
                Issue.record("An excluded async resumed download unexpectedly succeeded")
            } catch {
                failure = error as NSError
            }
            server.listener.poll()
            #expect(failure?.domain == D02RejectingProtocol.errorDomain)
            #expect(ExtendedRejectingProtocol.starts.withLock { $0 } == ["download"])
            #expect(server.listener.connections == 0)
        }

        @Test(arguments: [false, true])
        func `real upload resume data still reaches rejection`(completion: Bool) async throws {
            ExtendedRejectingProtocol.starts.withLock { $0 = [] }
            let server = try NativeHTTPServer()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(repeating: 65, count: 8 * 1024 * 1024).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let resumeData = try await nativeUploadResumeData(server: server, file: file)
            let delegate = D02TaskDelegate()
            let session = extendedRejectionSession(delegate)
            defer { session.invalidateAndCancel() }
            let task: URLSessionUploadTask = if completion {
                session.uploadTask(withResumeData: resumeData) { _, _, error in
                    delegate.completeOperation(error: error)
                }
            } else {
                session.uploadTask(withResumeData: resumeData)
            }
            task.resume()
            try #require(await d02Eventually {
                server.listener.poll() || delegate.outcome.withLock { $0.completed || $0.operationCompleted }
            })
            server.listener.poll()
            let result = delegate.outcome.withLock { $0 }
            let domain = completion ? result.operationErrorDomain : result.errorDomain
            print("D02 valid upload resume completion=\(completion): " +
                "starts=\(ExtendedRejectingProtocol.starts.withLock { $0 }), created=\(result.createdKinds), " +
                "error=\(domain ?? "nil"), connections=\(server.listener.connections)")
            #expect(server.listener.connections == 0)
            #expect(ExtendedRejectingProtocol.starts.withLock { $0 } == ["upload"])
            #expect(domain == D02RejectingProtocol.errorDomain)
        }

        @Test(arguments: [false, true])
        func `real download resume data still reaches rejection`(completion: Bool) async throws {
            ExtendedRejectingProtocol.starts.withLock { $0 = [] }
            let server = try NativeHTTPServer()
            let resumeData = try await nativeResumeData(server: server)
            let delegate = D02TaskDelegate()
            let session = extendedRejectionSession(delegate)
            defer { session.invalidateAndCancel() }
            let task: URLSessionDownloadTask = if completion {
                session.downloadTask(withResumeData: resumeData) { _, _, error in
                    delegate.completeOperation(error: error)
                }
            } else {
                session.downloadTask(withResumeData: resumeData)
            }
            task.resume()
            try #require(await d02Eventually {
                server.listener.poll() || delegate.outcome.withLock { $0.completed || $0.operationCompleted }
            })
            server.listener.poll()
            let result = delegate.outcome.withLock { $0 }
            let domain = completion ? result.operationErrorDomain : result.errorDomain
            let starts = ExtendedRejectingProtocol.starts.withLock { $0 }
            print("D02 valid resume completion=\(completion): starts=\(starts), " +
                "created=\(result.createdKinds), error=\(domain ?? "nil"), connections=\(server.listener.connections)")
            #expect(server.listener.connections == 0)
            #expect(ExtendedRejectingProtocol.starts.withLock { $0 } == ["download"])
            #expect(domain == D02RejectingProtocol.errorDomain)
        }
    #else
        @Test(arguments: ["nativeDelegate", "nativeCompletion", "interceptedDelegate", "interceptedCompletion"])
        func `resume constructors preserve native Linux failure channels`(presentation: String) async throws {
            ExtendedRejectingProtocol.starts.withLock { $0 = [] }
            let listener = try D02LoopbackListener()
            let observer = D02TaskDelegate()
            let configuration = URLSessionConfiguration.ephemeral
            if presentation.hasPrefix("intercepted") {
                configuration.protocolClasses = [ExtendedRejectingProtocol.self]
            }
            let session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            // Release source ignores every resume blob. This deliberately
            // invalid input tests its native failure channels, not resumption.
            let data = Data("http://127.0.0.1:\(listener.port)/ignored-resume".utf8)
            let completion = presentation.hasSuffix("Completion")
            let task: URLSessionDownloadTask = if completion {
                session.downloadTask(withResumeData: data) { _, _, error in observer.completeOperation(error: error) }
            } else {
                session.downloadTask(withResumeData: data)
            }
            task.resume()
            try #require(await d02Eventually { observer.outcome.withLock { $0.completed || $0.operationCompleted } })
            try #require(await d02Eventually { task.state == .completed })
            listener.poll()
            let result = observer.outcome.withLock { $0 }
            let domain = completion ? result.operationErrorDomain : result.errorDomain
            let code = completion ? result.operationErrorCode : result.errorCode
            #expect(domain == NSURLErrorDomain)
            #expect(code == URLError.unsupportedURL.rawValue)
            #expect((task.error as NSError?)?.code == code)
            #expect(task.originalRequest == nil)
            #expect(ExtendedRejectingProtocol.starts.withLock { $0.isEmpty })
            #expect(listener.connections == 0)
            print("D02 Linux resume \(presentation): error=\(domain ?? "nil")/\(code ?? 0), starts=0")
        }
    #endif
}

private func runAsyncExcluded(_ kind: String, session: URLSession, request: URLRequest,
                              file: URL, delegate: D02TaskDelegate?) async throws
{
    switch kind {
    case "fileUpload": _ = try await session.upload(for: request, fromFile: file, delegate: delegate)
    case "dataUpload": _ = try await session.upload(for: request, from: Data("data-body".utf8), delegate: delegate)
    case "downloadRequest":
        let (file, _) = try await session.download(for: request, delegate: delegate)
        try? FileManager.default.removeItem(at: file)
    default:
        let (file, _) = try await session.download(from: request.url!, delegate: delegate)
        try? FileManager.default.removeItem(at: file)
    }
}

private func makeExcludedTask(_ kind: String, completion: Bool, session: URLSession,
                              delegate: D02TaskDelegate, locations: (remote: URL, file: URL)) -> URLSessionTask
{
    let url = locations.remote
    let file = locations.file
    var request = URLRequest(url: url)
    request.httpMethod = kind.hasSuffix("Upload") ? "POST" : "GET"
    switch (kind, completion) {
    case ("fileUpload", true):
        return session.uploadTask(with: request, fromFile: file) { _, _, error in
            delegate.completeOperation(error: error)
        }
    case ("fileUpload", false): return session.uploadTask(with: request, fromFile: file)
    case ("dataUpload", true):
        return session.uploadTask(with: request, from: Data("data-body".utf8)) { _, _, error in
            delegate.completeOperation(error: error)
        }
    case ("dataUpload", false): return session.uploadTask(with: request, from: Data("data-body".utf8))
    case ("downloadRequest", true):
        return session.downloadTask(with: request) { _, _, error in delegate.completeOperation(error: error) }
    case ("downloadRequest", false): return session.downloadTask(with: request)
    case ("downloadURL", true):
        return session.downloadTask(with: url) { _, _, error in delegate.completeOperation(error: error) }
    default: return session.downloadTask(with: url)
    }
}
