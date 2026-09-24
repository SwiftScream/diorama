import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

private let controlledModes: [String] = {
    var modes = ["allow", "cancel", "pending", "taskCancel", "download"]
    #if canImport(Darwin)
        modes.append("stream")
    #endif
    return modes
}()

func d02StartPresentedRequest(_ presentation: String, session: URLSession,
                              consumer: D02ControlledConsumer, url: URL,
                              cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) async throws
{
    let request = URLRequest(url: url, cachePolicy: cachePolicy)
    switch presentation {
    case "delegateURL": session.dataTask(with: url).resume()
    case "delegateRequest": session.dataTask(with: request).resume()
    case "completionURL":
        session.dataTask(with: url) { data, _, error in consumer.complete(data: data, error: error) }.resume()
    case "completionRequest":
        session.dataTask(with: request) { data, _, error in consumer.complete(data: data, error: error) }.resume()
    default:
        let data: Data
        if presentation.hasSuffix("URL") {
            (data, _) = try await session.data(from: url,
                                               delegate: presentation.hasPrefix("asyncDelegate") ? consumer : nil)
        } else {
            (data, _) = try await session.data(for: request,
                                               delegate: presentation.hasPrefix("asyncDelegate") ? consumer : nil)
        }
        consumer.complete(data: data, error: nil)
    }
}

@Suite(.serialized)
struct D02ControlledDeliveryTests {
    @Test(arguments: d02DataPresentations)
    func `separately delivered chunks preserve every presentation`(presentation: String) async throws {
        let listener = try D02LoopbackListener()
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/timed"))
        let consumer = D02ControlledConsumer()
        let session = d02ControlledSession(consumer)
        let producer = Task {
            try await d02StartPresentedRequest(presentation, session: session, consumer: consumer, url: url)
        }
        defer {
            D02ControlledProtocol.active.withLock { $0 }?.stop()
            session.invalidateAndCancel()
            producer.cancel()
        }
        try #require(await d02Eventually { D02ControlledProtocol.active.withLock { $0 != nil } })
        let delivery = try #require(D02ControlledProtocol.active.withLock { $0 })
        delivery.head()
        #expect(delivery.bytes("first-"))
        if presentation.hasPrefix("delegate") {
            try #require(await d02Eventually { consumer.result.withLock { $0.body == Data("first-".utf8) } })
        } else {
            try await Task.sleep(for: .milliseconds(150))
            #expect(!consumer.result.withLock { $0.completed })
        }
        #expect(delivery.bytes("second"))
        delivery.finish()
        try #require(await d02Eventually { consumer.result.withLock { $0.completed } })
        try await producer.value
        listener.poll()
        let result = consumer.result.withLock { $0 }
        print("D02 controlled \(presentation): chunks=\(result.chunks.map(\.count)), " +
            "body=\(String(data: result.body, encoding: .utf8) ?? "invalid"), connections=\(listener.connections)")
        withKnownLinuxIssue("FN-01: custom-protocol aggregates retain only the last chunk",
                            affected: !presentation.hasPrefix("delegate"))
        {
            #expect(result.body == Data("first-second".utf8))
        }
        #expect(result.errorDomain == nil)
        #expect(listener.connections == 0)
    }

    @Test(arguments: controlledModes)
    func `controlled response decisions match the supported boundary`(mode: String) async throws {
        let listener = try D02LoopbackListener()
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/decision"))
        let consumer = D02ControlledConsumer(mode: mode)
        let session = d02ControlledSession(consumer)
        defer {
            D02ControlledProtocol.active.withLock { $0 }?.stop()
            consumer.allowPending()
            session.invalidateAndCancel()
        }
        session.dataTask(with: url).resume()
        try #require(await d02Eventually { D02ControlledProtocol.active.withLock { $0 != nil } })
        let delivery = try #require(D02ControlledProtocol.active.withLock { $0 })
        delivery.head()
        try #require(await d02Eventually { consumer.result.withLock { $0.head } })
        delivery.bytes("first-")
        try await Task.sleep(for: .milliseconds(100))
        delivery.bytes("second")
        delivery.finish()
        if mode == "pending" {
            try await Task.sleep(for: .milliseconds(100))
            #if canImport(FoundationNetworking)
                #expect(await d02Eventually { consumer.result.withLock { $0.completed } })
            #else
                #expect(consumer.result.withLock { $0.body.isEmpty && !$0.completed })
            #endif
            consumer.allowPending()
        }
        try #require(await d02Eventually { consumer.result.withLock { $0.completed } })
        listener.poll()
        let result = consumer.result.withLock { $0 }
        checkDecision(result, mode: mode)
        #expect(listener.connections == 0)
        #expect(!delivery.bytes("after-terminal"))
    }
}

private func checkDecision(_ result: D02ControlledResult, mode: String) {
    print("D02 controlled decision \(mode): chunks=\(result.chunks.map(\.count)), " +
        "error=\(result.errorDomain ?? "nil")/\(result.errorCode ?? 0), diagnostics=\(result.diagnostics)")
    #if canImport(FoundationNetworking)
        let canceled = mode == "taskCancel"
    #else
        let canceled = mode == "taskCancel" || mode == "cancel"
    #endif
    if mode == "download" || mode == "stream" {
        #expect(result.errorDomain == "D02UnsupportedConversion")
        #if canImport(Darwin)
            let disposition: URLSession.ResponseDisposition = mode == "stream" ? .becomeStream : .becomeDownload
        #else
            let disposition = URLSession.ResponseDisposition(rawValue: 2)!
        #endif
        #expect(result.diagnostics == [String(disposition.rawValue)])
        #expect(result.body.isEmpty)
    } else if canceled {
        #expect(result.errorDomain == NSURLErrorDomain)
        #expect(result.errorCode == URLError.cancelled.rawValue)
        #expect(result.body.isEmpty)
    } else {
        #expect(result.errorDomain == nil)
        #expect(result.body == Data("first-second".utf8))
    }
}
