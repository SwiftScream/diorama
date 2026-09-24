import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization
import Testing

private struct ConstructorRequest: Sendable {
    let method: String?
    let body: Data?
    let hasStream: Bool
    let taskKind: String
    let originalBody: Data?
    let originalHasStream: Bool
    let currentBody: Data?
    let currentHasStream: Bool
}

private final class ConstructorProtocol: URLProtocol {
    static let requests = Mutex<[ConstructorRequest]>([])

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
        Self.requests.withLock {
            $0.append(ConstructorRequest(method: request.httpMethod, body: request.httpBody,
                                         hasStream: request.httpBodyStream != nil, taskKind: d02Kind(of: task),
                                         originalBody: task?.originalRequest?.httpBody,
                                         originalHasStream: task?.originalRequest?.httpBodyStream != nil,
                                         currentBody: task?.currentRequest?.httpBody,
                                         currentHasStream: task?.currentRequest?.httpBodyStream != nil))
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 203, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": "2"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct ConstructorResult: Sendable {
    var body = Data()
    var status: Int?
    var completed = false
    var errorDomain: String?
    var heads = 0
    var dataCallbacks = 0
}

private final class ConstructorDelegate: NSObject, URLSessionDataDelegate {
    let result = Mutex(ConstructorResult())

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        result.withLock {
            $0.heads += 1
            $0.status = (response as? HTTPURLResponse)?.statusCode
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        result.withLock {
            $0.dataCallbacks += 1
            $0.body.append(data)
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        result.withLock {
            $0.status = (task.response as? HTTPURLResponse)?.statusCode
            $0.errorDomain = (error as NSError?)?.domain
            $0.completed = true
        }
    }

    func finish(data: Data?, response: URLResponse?, error: (any Error)?) {
        result.withLock {
            $0.body = data ?? Data()
            $0.status = (response as? HTTPURLResponse)?.statusCode
            $0.errorDomain = (error as NSError?)?.domain
            $0.completed = true
        }
    }
}

private func runConstructor(_ presentation: String, request: URLRequest, session: URLSession,
                            receiver: ConstructorDelegate, taskDelegate: ConstructorDelegate) async throws
{
    switch presentation {
    case "delegate": session.dataTask(with: request).resume()
    case "taskOverride":
        let task = session.dataTask(with: request)
        task.delegate = taskDelegate
        #expect(task.delegate === taskDelegate)
        task.resume()
    case "completion":
        session.dataTask(with: request) { data, response, error in
            receiver.finish(data: data, response: response, error: error)
        }.resume()
    default:
        let selectedDelegate = presentation == "asyncTaskDelegate" ? taskDelegate : nil
        let (data, response) = try await session.data(for: request,
                                                      delegate: selectedDelegate)
        receiver.finish(data: data, response: response, error: nil)
    }
}

private func checkConstructor(_ observed: ConstructorRequest, input: URLRequest,
                              result: ConstructorResult, presentation: String, bodyKind: String)
{
    print("D02 constructor \(presentation)/\(bodyKind): " +
        "bodyCount=\(observed.body.map { String($0.count) } ?? "nil"), stream=\(observed.hasStream), " +
        "originalBodyCount=\(observed.originalBody.map { String($0.count) } ?? "nil"), " +
        "originalStream=\(observed.originalHasStream), " +
        "currentBodyCount=\(observed.currentBody.map { String($0.count) } ?? "nil"), " +
        "currentStream=\(observed.currentHasStream), kind=\(observed.taskKind), " +
        "result=\(String(data: result.body, encoding: .utf8) ?? "invalid UTF-8")")
    #expect(observed.method == "POST")
    // Foundation may expose an in-memory body as a stream in the protocol's
    // request. For the initial request, the task's original retains its form.
    // Redirect-derived requests need their own D03 evidence.
    #expect(observed.originalBody == input.httpBody)
    #expect(observed.originalHasStream == (bodyKind == "stream"))
    #expect(observed.taskKind == "data")
    #expect(result.body == Data("ok".utf8))
    #expect(result.status == 203)
    #expect(result.errorDomain == nil)
}

@Suite(.serialized)
struct D02ConstructorTests {
    @Test(arguments: ["delegate", "completion", "async", "asyncTaskDelegate", "taskOverride"],
          ["absent", "empty", "bytes", "stream"])
    func `request constructors expose initial body form and delegate selection`(presentation: String,
                                                                                bodyKind: String) async throws
    {
        ConstructorProtocol.requests.withLock { $0 = [] }
        let listener = try D02LoopbackListener()
        let url = try #require(URL(string: "http://127.0.0.1:\(listener.port)/constructors"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let expectedBody: Data? = switch bodyKind {
        case "empty": Data()
        case "bytes": Data([0, 1, 127, 255])
        default: nil
        }
        request.httpBody = expectedBody
        if bodyKind == "stream" {
            request.httpBodyStream = InputStream(data: Data([0, 1, 127, 255]))
        }
        let sessionDelegate = ConstructorDelegate()
        let taskDelegate = ConstructorDelegate()
        let receiver = presentation == "taskOverride" ? taskDelegate : sessionDelegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConstructorProtocol.self]
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        try await runConstructor(presentation, request: request, session: session,
                                 receiver: receiver, taskDelegate: taskDelegate)
        try #require(await d02Eventually {
            sessionDelegate.result.withLock { $0.completed } || taskDelegate.result.withLock { $0.completed }
        })
        listener.poll()
        let sessionResult = sessionDelegate.result.withLock { $0 }
        let taskResult = taskDelegate.result.withLock { $0 }
        let result = taskResult.completed ? taskResult : sessionResult
        let observations = ConstructorProtocol.requests.withLock { $0 }
        let observed = try #require(observations.first)
        checkConstructor(observed, input: request, result: result, presentation: presentation, bodyKind: bodyKind)
        print("D02 constructor \(presentation)/\(bodyKind) delegates: " +
            "sessionHeads=\(sessionResult.heads), taskHeads=\(taskResult.heads), connections=\(listener.connections)")
        #expect(observations.count == 1)
        #expect(listener.connections == 0)
        if presentation == "taskOverride" {
            #expect(sessionResult.heads == 0)
            #expect(taskResult.heads == 1)
            #expect(taskResult.completed)
        }
    }
}
