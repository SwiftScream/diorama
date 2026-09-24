import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization
import Testing

private struct CreationDiagnostic: Equatable, Sendable {
    let attachment: String
    let kind: String
}

private final class CreationLedger: Sendable {
    let entries = Mutex<[CreationDiagnostic]>([])
}

/// A native-hook probe with a minimal test ledger, not a production reporter.
private final class DiagnosticDelegate: NSObject, URLSessionTaskDelegate {
    let attachment: String
    let ledger: CreationLedger
    let observer: D02TaskDelegate
    let sink: @Sendable (CreationDiagnostic, URLSessionTask) -> Void

    init(attachment: String, ledger: CreationLedger, observer: D02TaskDelegate,
         sink: @escaping @Sendable (CreationDiagnostic, URLSessionTask) -> Void)
    {
        self.attachment = attachment
        self.ledger = ledger
        self.observer = observer
        self.sink = sink
    }

    func urlSession(_: URLSession, didCreateTask task: URLSessionTask) {
        let kind = d02Kind(of: task)
        guard kind == "stream" || kind == "webSocket" else { return }
        task.cancel()
        let diagnostic = CreationDiagnostic(attachment: attachment, kind: kind)
        ledger.entries.withLock { $0.append(diagnostic) }
        sink(diagnostic, task)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        observer.urlSession(session, task: task, didCompleteWithError: error)
    }
}

private final class DiagnosticFallbackProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: NSError(domain: "D02UnexpectedInterception", code: 1))
    }

    override func stopLoading() {}
}

struct D02DiagnosticTests {
    #if canImport(Darwin)
        @Test(arguments: [D02TaskKind.stream, .webSocket])
        func `rejection retains attributed diagnostics before reentrant sinks`(kind: D02TaskKind) async throws {
            let ledger = CreationLedger()
            let sinkEvents = Mutex<[CreationDiagnostic]>([])
            let listener = try D02LoopbackListener()
            var tasks: [URLSessionTask] = []
            var sessions: [URLSession] = []
            var observers: [D02TaskDelegate] = []
            defer { sessions.forEach { $0.invalidateAndCancel() } }

            for attachment in ["left", "right"] {
                let observer = D02TaskDelegate()
                let delegate = DiagnosticDelegate(
                    attachment: attachment, ledger: ledger, observer: observer)
                { diagnostic, task in
                    #expect(ledger.entries.withLock { $0.contains(diagnostic) })
                    sinkEvents.withLock { $0.append(diagnostic) }
                    // Reenter native work before the factory has returned its task.
                    task.resume()
                    d02StartOperation(task, delegate: observer)
                }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [DiagnosticFallbackProtocol.self]
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                sessions.append(session)
                let task = d02Task(kind: kind, session: session, port: listener.port)
                tasks.append(task)
                observers.append(observer)
                #expect(ledger.entries.withLock { $0.last?.attachment } == attachment)
            }

            #expect(await d02Eventually {
                listener.poll() || observers.allSatisfy { observer in
                    observer.outcome.withLock { $0.completed && $0.operationCompleted }
                }
            })
            listener.poll()
            #expect(listener.connections == 0)
            let expected = ["left", "right"].map { CreationDiagnostic(attachment: $0, kind: kind.rawValue) }
            #expect(ledger.entries.withLock { $0 } == expected)
            #expect(sinkEvents.withLock { $0 } == expected)
            for (task, observer) in zip(tasks, observers) {
                let result = observer.outcome.withLock { $0 }
                #expect(result.errorDomain == NSURLErrorDomain)
                #expect(result.errorCode == URLError.cancelled.rawValue)
                #expect(result.operationErrorDomain == NSURLErrorDomain)
                #expect(result.operationErrorCode == URLError.cancelled.rawValue)
                #expect((task.error as NSError?)?.code == URLError.cancelled.rawValue)
            }
        }
    #else
        @Test
        func `unsupported Linux WebSockets preserve offline native refusal`() async throws {
            let ledger = CreationLedger()
            let observer = D02TaskDelegate()
            let delegate = DiagnosticDelegate(attachment: "linux", ledger: ledger, observer: observer) { _, _ in
                Issue.record("The tested Linux profile unexpectedly acquired a creation hook")
            }
            let listener = try D02LoopbackListener()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DiagnosticFallbackProtocol.self]
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let task = d02Task(kind: .webSocket, session: session, port: listener.port)
            task.resume()
            d02StartOperation(task, delegate: observer)
            #expect(await d02Eventually { observer.outcome.withLock { $0.completed && $0.operationCompleted } })
            listener.poll()
            let result = observer.outcome.withLock { $0 }
            #expect(listener.connections == 0)
            #expect(ledger.entries.withLock { $0.isEmpty })
            #expect(result.errorDomain == NSURLErrorDomain)
            #expect(result.errorCode == URLError.unsupportedURL.rawValue)
            #expect(result.operationErrorCode == URLError.unsupportedURL.rawValue)
        }
    #endif
}
