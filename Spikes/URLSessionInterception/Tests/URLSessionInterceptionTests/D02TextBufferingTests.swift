import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization
import Testing

/// Uses its own protocol state, so it can run alongside the controlled suite.
private final class TextProtocol: URLProtocol {
    static let active = Mutex<D02ControlledDelivery?>(nil)
    private let delivery = Mutex<D02ControlledDelivery?>(nil)

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let delivery = D02ControlledDelivery(self)
        self.delivery.withLock { $0 = delivery }
        Self.active.withLock { $0 = delivery }
    }

    override func stopLoading() {
        delivery.withLock { $0 }?.stop()
    }
}

struct D02TextBufferingTests {
    @Test
    func `text buffering matches a native HTTP control`() async throws {
        let native = try NativeHTTPServer()
        let nativeConsumer = D02ControlledConsumer()
        let nativeSession = URLSession(configuration: .ephemeral, delegate: nativeConsumer, delegateQueue: nil)
        let nativeURL = try #require(URL(string: "http://127.0.0.1:\(native.listener.port)/text"))
        let replayConsumer = D02ControlledConsumer()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TextProtocol.self]
        configuration.urlCache = nil
        let replaySession = URLSession(configuration: configuration, delegate: replayConsumer, delegateQueue: nil)
        defer {
            TextProtocol.active.withLock { $0 }?.stop()
            nativeSession.invalidateAndCancel()
            replaySession.invalidateAndCancel()
        }
        nativeSession.dataTask(with: nativeURL).resume()
        replaySession.dataTask(with: nativeURL).resume()
        try #require(await d02Eventually { native.receiveRequest() && TextProtocol.active.withLock { $0 != nil } })
        let delivery = try #require(TextProtocol.active.withLock { $0 })
        try #require(native.send(NativeHTTPServer.responseStart.replacingOccurrences(
            of: "application/octet-stream", with: "text/plain")))
        delivery.head(contentType: "text/plain")
        delivery.bytes("first-")
        try await Task.sleep(for: .milliseconds(200))
        let beforeNative = nativeConsumer.result.withLock { $0 }
        let beforeReplay = replayConsumer.result.withLock { $0 }
        print("D02 text before finish: nativeHead=\(beforeNative.head), customHead=\(beforeReplay.head), " +
            "nativeChunks=\(beforeNative.chunks.map(\.count)), customChunks=\(beforeReplay.chunks.map(\.count))")
        #expect(beforeNative.head == beforeReplay.head)
        #expect(beforeNative.body == beforeReplay.body)
        try #require(native.send("second"))
        delivery.bytes("second")
        delivery.finish()
        try #require(await d02Eventually {
            nativeConsumer.result.withLock { $0.completed } && replayConsumer.result.withLock { $0.completed }
        })
        #expect(nativeConsumer.result.withLock { $0.body } == Data("first-second".utf8))
        #expect(replayConsumer.result.withLock { $0.body } == Data("first-second".utf8))
        native.listener.poll()
        #expect(native.listener.connections == 0)
    }
}
