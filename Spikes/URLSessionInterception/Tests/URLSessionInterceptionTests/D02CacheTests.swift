import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization
import Testing

private final class FreshProtocol: URLProtocol {
    static let starts = Mutex(0)
    static let checks = Mutex<[String]>([])
    override static func canInit(with request: URLRequest) -> Bool {
        checks.withLock { $0.append("request:\(request.cachePolicy.rawValue)") }
        return true
    }

    override static func canInit(with task: URLSessionTask) -> Bool {
        checks.withLock { $0.append("task:\(task.currentRequest?.cachePolicy.rawValue ?? 99)") }
        return true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        checks.withLock { $0.append("canonical:\(request.cachePolicy.rawValue)") }
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    override func startLoading() {
        Self.starts.withLock { $0 += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 203, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "5"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("fresh".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func seededConfiguration(ephemeral: Bool, url: URL) throws -> URLSessionConfiguration {
    let configuration = ephemeral ? URLSessionConfiguration.ephemeral : .default
    let cache = URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 0, diskPath: nil)
    let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                headerFields: ["Cache-Control": "public, max-age=3600"]))
    cache.storeCachedResponse(CachedURLResponse(response: response, data: Data("cached".utf8)),
                              for: URLRequest(url: url))
    #expect(cache.cachedResponse(for: URLRequest(url: url))?.data == Data("cached".utf8))
    configuration.urlCache = cache
    configuration.timeoutIntervalForRequest = d02WatchdogSeconds
    return configuration
}

@Suite(.serialized)
struct D02CacheTests {
    @Test(arguments: d02DataPresentations, [false, true])
    func `seeded cache cannot bypass the copied uncached configuration`(presentation: String,
                                                                        ephemeral: Bool) async throws
    {
        FreshProtocol.starts.withLock { $0 = 0 }
        FreshProtocol.checks.withLock { $0 = [] }
        let listener = try D02LoopbackListener()
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/cache"))
        let original = try seededConfiguration(ephemeral: ephemeral, url: url)
        let baseline = URLSession(configuration: original)
        defer { baseline.invalidateAndCancel() }
        let cacheRequest = URLRequest(url: url, cachePolicy: .returnCacheDataDontLoad)
        let (cached, _) = try await baseline.data(for: cacheRequest)
        #expect(cached == Data("cached".utf8))
        let copy = try #require(original.copy() as? URLSessionConfiguration)
        copy.urlCache = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.protocolClasses = [FreshProtocol.self]
        #expect(original.urlCache != nil)
        let consumer = D02ControlledConsumer()
        let session = URLSession(configuration: copy, delegate: consumer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            try await d02StartPresentedRequest(presentation, session: session, consumer: consumer, url: url,
                                               cachePolicy: .returnCacheDataDontLoad)
        } catch {
            consumer.complete(data: nil, error: error)
        }
        try #require(await d02Eventually { consumer.result.withLock { $0.completed } })
        listener.poll()
        let starts = FreshProtocol.starts.withLock { $0 }
        print("D02 seeded cache \(presentation)/ephemeral=\(ephemeral): starts=\(starts), " +
            "bytes=\(consumer.result.withLock { $0.body.count }), connections=\(listener.connections), " +
            "checks=\(FreshProtocol.checks.withLock { $0 })")
        #expect(consumer.result.withLock { $0.body } == Data("fresh".utf8))
        #expect(consumer.result.withLock { $0.errorDomain } == nil)
        #expect(FreshProtocol.starts.withLock { $0 } == 1)
        #expect(listener.connections == 0)
    }
}
