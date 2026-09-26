import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization

let d02DataPresentations = [
    "delegateURL", "delegateRequest", "completionURL", "completionRequest",
    "asyncURL", "asyncRequest", "asyncDelegateURL", "asyncDelegateRequest",
]

/// Test-only synchronization for a Foundation object that is not Sendable.
/// Every emitted client callback and stop runs under this recursive lock;
/// reentrant stop can clear the reference without deadlocking. Terminal events
/// clear it before invoking the client. No caller receives the stored protocol.
/// This proves controlled delivery, not D05's full native quiescence contract.
final class D02ControlledDelivery: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var instance: URLProtocol?

    init(_ instance: URLProtocol) {
        self.instance = instance
    }

    func head(contentType: String = "application/octet-stream", response suppliedResponse: URLResponse? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let instance, let url = instance.request.url,
              let response = HTTPURLResponse(url: url, statusCode: 203, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": "12", "Content-Type": contentType])
        else { return }
        instance.client?.urlProtocol(instance, didReceive: suppliedResponse ?? response,
                                     cacheStoragePolicy: .notAllowed)
    }

    @discardableResult
    func bytes(_ text: String) -> Bool {
        bytes(Data(text.utf8))
    }

    @discardableResult
    func bytes(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let instance else { return false }
        instance.client?.urlProtocol(instance, didLoad: data)
        return true
    }

    func finish(error: NSError? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let instance else { return }
        self.instance = nil
        if let error {
            instance.client?.urlProtocol(instance, didFailWithError: error)
        } else {
            instance.client?.urlProtocolDidFinishLoading(instance)
        }
    }

    /// Return whether delivery was still open, so cleanup need not cancel a
    /// task whose terminal callback is already draining through Foundation.
    @discardableResult
    func stop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasOpen = instance != nil
        instance = nil
        return wasOpen
    }

    /// D03 uses the same callback/stop lock for a native redirect notification.
    /// The old instance remains available until Foundation stops it or the
    /// delegate refuses and the fixture delivers the redirect response body.
    func redirect(to request: URLRequest, response: HTTPURLResponse) {
        lock.lock()
        defer { lock.unlock() }
        guard let instance else { return }
        instance.client?.urlProtocol(instance, wasRedirectedTo: request, redirectResponse: response)
    }

    /// D04 presents a protocol-owned challenge through the native client.
    /// Its delegate proxy observes the ordinary native completion decision;
    /// consumer code never calls the protocol's custom sender.
    func challenge(_ challenge: URLAuthenticationChallenge) {
        lock.lock()
        defer { lock.unlock() }
        guard let instance else { return }
        instance.client?.urlProtocol(instance, didReceive: challenge)
    }
}

final class D02ControlledProtocol: URLProtocol {
    static let active = Mutex<D02ControlledDelivery?>(nil)
    private let delivery = Mutex<D02ControlledDelivery?>(nil)

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
        let delivery = D02ControlledDelivery(self)
        self.delivery.withLock { $0 = delivery }
        Self.active.withLock { $0 = delivery }
    }

    override func stopLoading() {
        delivery.withLock { $0 }?.stop()
    }
}

struct D02ControlledResult: Sendable {
    var head = false
    var chunks: [Data] = []
    var completed = false
    var errorDomain: String?
    var errorCode: Int?
    var pending: (@Sendable (URLSession.ResponseDisposition) -> Void)?
    var diagnostics: [String] = []

    var body: Data {
        chunks.reduce(into: Data()) { $0.append($1) }
    }
}

final class D02ControlledConsumer: NSObject, URLSessionDataDelegate {
    let mode: String
    let result = Mutex(D02ControlledResult())

    init(mode: String = "allow") {
        self.mode = mode
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        switch mode {
        case "pending": result.withLock { $0.pending = completionHandler }
        case "cancel": completionHandler(.cancel)
        case "taskCancel":
            dataTask.cancel()
            completionHandler(.allow)
        case "download", "stream":
            let consumer = D02ConversionRequester(stream: mode == "stream")
            consumer.urlSession(session, dataTask: dataTask, didReceive: response) { decision in
                self.result.withLock { $0.diagnostics.append(String(decision.rawValue)) }
                D02ControlledProtocol.active.withLock { $0 }?.finish(
                    error: NSError(domain: "D02UnsupportedConversion", code: 1))
                // Delivery is already terminal. Release Foundation's response
                // wait without replacing the infrastructure error with -999.
                completionHandler(.allow)
            }
        default: completionHandler(.allow)
        }
        result.withLock { $0.head = true }
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        result.withLock { $0.chunks.append(data) }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        complete(data: nil, error: error)
    }

    func complete(data: Data?, error: (any Error)?) {
        result.withLock {
            if let data {
                $0.chunks = [data]
            }
            $0.errorDomain = (error as NSError?)?.domain
            $0.errorCode = (error as NSError?)?.code
            $0.completed = true
        }
    }

    func allowPending() {
        let pending = result.withLock { state in
            defer { state.pending = nil }
            return state.pending
        }
        pending?(.allow)
    }
}

private final class D02ConversionRequester: NSObject, URLSessionDataDelegate {
    let stream: Bool
    init(stream: Bool) {
        self.stream = stream
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive _: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        #if canImport(Darwin)
            completionHandler(stream ? .becomeStream : .becomeDownload)
        #else
            // This release deprecates the named case because conversion is
            // unimplemented. Construct its raw value only to probe rejection.
            completionHandler(URLSession.ResponseDisposition(rawValue: 2)!)
        #endif
    }
}

func d02ControlledSession(_ delegate: D02ControlledConsumer) -> URLSession {
    D02ControlledProtocol.active.withLock { $0 = nil }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.protocolClasses = [D02ControlledProtocol.self]
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
}
