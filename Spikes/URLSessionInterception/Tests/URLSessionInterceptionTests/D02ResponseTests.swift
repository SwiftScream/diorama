import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization
import Testing

private final class TwoChunkProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 203, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": "12", "X-D02": "chunks"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("first-".utf8))
        client?.urlProtocol(self, didLoad: Data("second".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct ResponseObservation: Sendable {
    var status: Int?
    var header: String?
    var chunks: [Data] = []
    var completed = false
    var errorDomain: String?
    var errorCode: Int?

    var body: Data {
        chunks.reduce(into: Data()) { $0.append($1) }
    }
}

private final class ResponseDelegate: NSObject, URLSessionDataDelegate {
    let observation = Mutex(ResponseObservation())
    let cancelResponse: Bool

    init(cancelResponse: Bool = false) {
        self.cancelResponse = cancelResponse
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        observation.withLock {
            $0.status = (response as? HTTPURLResponse)?.statusCode
            $0.header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-D02")
        }
        completionHandler(cancelResponse ? .cancel : .allow)
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

    func finish(data: Data?, response: URLResponse?, error: (any Error)?) {
        observation.withLock {
            $0.status = (response as? HTTPURLResponse)?.statusCode
            $0.header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-D02")
            $0.chunks = data.map { [$0] } ?? []
            $0.errorDomain = (error as NSError?)?.domain
            $0.errorCode = (error as NSError?)?.code
            $0.completed = true
        }
    }
}

private func responseSession(delegate: ResponseDelegate?) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TwoChunkProtocol.self]
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
}

struct D02ResponseTests {
    @Test(arguments: ["delegate", "completion", "async"])
    func `two chunks preserve the complete response body`(presentation: String) async throws {
        let listener = try D02LoopbackListener()
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/chunks"))
        let observer = ResponseDelegate()
        let session = responseSession(delegate: presentation == "delegate" ? observer : nil)
        defer { session.invalidateAndCancel() }
        switch presentation {
        case "delegate":
            session.dataTask(with: url).resume()
        case "completion":
            session.dataTask(with: url) { data, response, error in
                observer.finish(data: data, response: response, error: error)
            }.resume()
        default:
            let (data, response) = try await session.data(from: url)
            observer.finish(data: data, response: response, error: nil)
        }
        #expect(await d02Eventually { observer.observation.withLock { $0.completed } })
        listener.poll()
        let result = observer.observation.withLock { $0 }
        print("D02 response \(presentation): chunks=\(result.chunks.map(\.count)), " +
            "body=\(String(bytes: result.body, encoding: .utf8) ?? "invalid"), connections=\(listener.connections)")
        #expect(listener.connections == 0)
        #expect(result.status == 203)
        #expect(result.header == "chunks")
        #expect(result.errorDomain == nil)
        withKnownLinuxIssue("FN-01: custom-protocol aggregates retain only the last chunk",
                            affected: presentation != "delegate")
        {
            #expect(result.body == Data("first-second".utf8))
        }
    }

    @Test
    func `cancel response disposition prevents body delivery`() async throws {
        let listener = try D02LoopbackListener()
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/cancel"))
        let observer = ResponseDelegate(cancelResponse: true)
        let session = responseSession(delegate: observer)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: url).resume()
        #expect(await d02Eventually { observer.observation.withLock { $0.completed } })
        listener.poll()
        let result = observer.observation.withLock { $0 }
        print("D02 disposition cancel: chunks=\(result.chunks.map(\.count)), " +
            "error=\(result.errorDomain ?? "nil")/\(result.errorCode ?? 0), connections=\(listener.connections)")
        #expect(listener.connections == 0)
        #expect(result.status == 203)
        withKnownLinuxIssue("Former FN-02: accepted native response-disposition cancellation limitation") {
            #expect(result.body.isEmpty)
            #expect(result.errorDomain == NSURLErrorDomain)
            #expect(result.errorCode == URLError.cancelled.rawValue)
        }
    }
}
