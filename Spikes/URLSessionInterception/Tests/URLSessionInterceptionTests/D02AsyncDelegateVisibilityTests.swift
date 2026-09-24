import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization
import Testing

private struct DelegateVisibility: Sendable {
    var callbackGetter: String?
    var completed = false
    var data: Data?
    var errorDomain: String?
}

private final class IdentityDelegate: NSObject, URLSessionDataDelegate {
    let name: String
    let result = Mutex(DelegateVisibility())
    init(name: String) {
        self.name = name
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive _: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        result.withLock { $0.callbackGetter = (dataTask.delegate as? IdentityDelegate)?.name ?? "nil" }
        completionHandler(.allow)
    }

    func complete(data: Data?, error: (any Error)?) {
        result.withLock {
            $0.data = data
            $0.errorDomain = (error as NSError?)?.domain
            $0.completed = true
        }
    }
}

private final class VisibilityProtocol: URLProtocol {
    static let getterNames = Mutex<[String]>([])
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.getterNames.withLock { $0.append((task?.delegate as? IdentityDelegate)?.name ?? "nil") }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("body".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct D02AsyncDelegateVisibilityTests {
    @Test(arguments: [false, true], [false, true])
    func `async delegate is visible to a custom protocol`(supplied: Bool, requestForm: Bool) async throws {
        VisibilityProtocol.getterNames.withLock { $0 = [] }
        let listener = try D02LoopbackListener()
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/visibility"))
        let sessionDelegate = IdentityDelegate(name: "session")
        let taskDelegate = IdentityDelegate(name: "task")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.protocolClasses = [VisibilityProtocol.self]
        let session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let body: Data
        if requestForm {
            (body, _) = try await session.data(for: URLRequest(url: url), delegate: supplied ? taskDelegate : nil)
        } else {
            (body, _) = try await session.data(from: url, delegate: supplied ? taskDelegate : nil)
        }
        #if canImport(FoundationNetworking)
            if supplied {
                try #require(await d02Eventually { taskDelegate.result.withLock { $0.callbackGetter != nil } })
            }
        #endif
        listener.poll()
        let getters = VisibilityProtocol.getterNames.withLock { $0 }
        let callbackGetter = taskDelegate.result.withLock { $0.callbackGetter } ?? "none"
        print("D02 async visibility supplied=\(supplied), request=\(requestForm): " +
            "protocolGetters=\(getters), callbackGetter=\(callbackGetter)")
        #expect(body == Data("body".utf8))
        #expect(listener.connections == 0)
        if supplied {
            withKnownLinuxIssue("FN-08: the async-supplied delegate is hidden from task.delegate") {
                #expect(getters == ["task"])
            }
        }
    }

    #if canImport(FoundationNetworking)
        @Test(arguments: [false, true])
        func `native async response callback can identify its own task delegate`(requestForm: Bool) async throws {
            let server = try NativeHTTPServer()
            let url = try #require(URL(string: "http://127.0.0.1:\(server.listener.port)/visibility"))
            let sessionDelegate = IdentityDelegate(name: "session")
            let taskDelegate = IdentityDelegate(name: "task")
            let session = URLSession(configuration: .ephemeral, delegate: sessionDelegate, delegateQueue: nil)
            let request = Task {
                do {
                    let body: Data
                    if requestForm {
                        (body, _) = try await session.data(for: URLRequest(url: url), delegate: taskDelegate)
                    } else {
                        (body, _) = try await session.data(from: url, delegate: taskDelegate)
                    }
                    taskDelegate.complete(data: body, error: nil)
                } catch {
                    taskDelegate.complete(data: nil, error: error)
                }
            }
            defer {
                session.invalidateAndCancel()
                request.cancel()
            }
            try #require(await d02Eventually { server.receiveRequest() })
            try #require(server.send(NativeHTTPServer.responseStart + "second"))
            try #require(await d02Eventually {
                taskDelegate.result.withLock { $0.completed && $0.callbackGetter != nil }
            })
            await request.value
            let result = taskDelegate.result.withLock { $0 }
            print("D02 native async visibility request=\(requestForm): " +
                "callbackGetter=\(result.callbackGetter ?? "none")")
            #expect(result.data == Data("first-second".utf8))
            #expect(result.errorDomain == nil)
            withKnownLinuxIssue("FN-08: native async delegate identity is hidden from task.delegate") {
                #expect(result.callbackGetter == "task")
            }
        }
    #endif
}
