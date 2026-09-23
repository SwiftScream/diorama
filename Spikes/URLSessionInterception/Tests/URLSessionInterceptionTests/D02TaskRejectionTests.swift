import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

@Suite(.serialized)
struct D02TaskRejectionTests {
    @Test(arguments: D02TaskKind.allCases)
    func `protocol rejection precedes any connection`(kind: D02TaskKind) async throws {
        D02RejectingProtocol.observations.withLock { $0 = D02RejectionState() }
        let listener = try D02LoopbackListener()
        let delegate = D02TaskDelegate()
        let session = d02RejectingSession(delegate: delegate)
        let task = d02Task(kind: kind, session: session, port: listener.port)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        task.resume()
        d02StartOperation(task, delegate: delegate)

        #expect(await d02Eventually { listener.poll() || delegate.outcome.withLock { $0.completed } })
        listener.poll()
        let observation = D02RejectingProtocol.observations.withLock { $0 }
        let outcome = delegate.outcome.withLock { $0 }
        print("D02 rejection \(kind.rawValue): starts=\(observation.starts), " +
            "created=\(outcome.createdKinds), connections=\(listener.connections), " +
            "checks=\(observation.requestChecks)/\(observation.taskChecks), " +
            "error=\(outcome.errorDomain ?? "nil")/\(outcome.errorCode ?? 0), " +
            "marker=\(outcome.hasRejectionMarker), bodyStreamRequests=\(outcome.bodyStreamRequests)")
        #expect(listener.connections == 0)
        #expect(observation.starts.count == 1)
        #expect(outcome.errorDomain == D02RejectingProtocol.errorDomain)
    }

    #if canImport(Darwin)
        @Test(arguments: [D02TaskKind.webSocket, .stream])
        func `task creation cancellation prevents connection`(kind: D02TaskKind) async throws {
            D02RejectingProtocol.observations.withLock { $0 = D02RejectionState() }
            let listener = try D02LoopbackListener()
            let delegate = D02TaskDelegate(cancelOnCreation: true)
            let session = d02RejectingSession(delegate: delegate)
            let task = d02Task(kind: kind, session: session, port: listener.port)
            defer { session.invalidateAndCancel() }
            #expect(delegate.outcome.withLock { $0.createdKinds.count } == 1)
            task.resume()
            d02StartOperation(task, delegate: delegate)

            #expect(await d02Eventually {
                listener.poll() || delegate.outcome.withLock { $0.completed && $0.operationCompleted }
            })
            listener.poll()
            let outcome = delegate.outcome.withLock { $0 }
            print("D02 creation cancellation \(kind.rawValue): " +
                "connections=\(listener.connections), error=\(outcome.errorDomain ?? "nil")/\(outcome.errorCode ?? 0)")
            #expect(listener.connections == 0)
            #expect(outcome.errorDomain == NSURLErrorDomain)
            #expect(outcome.errorCode == URLError.cancelled.rawValue)
            // A delegate proxy cannot rewrite these native task/operation channels.
            #expect((task.error as NSError?)?.domain == NSURLErrorDomain)
            #expect((task.error as NSError?)?.code == URLError.cancelled.rawValue)
            #expect(outcome.operationErrorDomain == NSURLErrorDomain)
            #expect(outcome.operationErrorCode == URLError.cancelled.rawValue)
        }
    #endif

    @Test(arguments: ["data:text/plain,probe", "d02-unsupported://local/probe"])
    func `non HTTP schemes reach rejection`(url: String) async throws {
        D02RejectingProtocol.observations.withLock { $0 = D02RejectionState() }
        let delegate = D02TaskDelegate()
        let session = d02RejectingSession(delegate: delegate)
        defer { session.invalidateAndCancel() }
        let task = try session.dataTask(with: #require(URL(string: url)))
        task.resume()

        #expect(await d02Eventually { delegate.outcome.withLock { $0.completed } })
        #expect(D02RejectingProtocol.observations.withLock { $0.starts } == ["data"])
        #expect(delegate.outcome.withLock { $0.errorDomain } == D02RejectingProtocol.errorDomain)
    }

    @Test
    func `data body stream remains visible for rejection`() async throws {
        D02RejectingProtocol.observations.withLock { $0 = D02RejectionState() }
        let listener = try D02LoopbackListener()
        let delegate = D02TaskDelegate()
        let session = d02RejectingSession(delegate: delegate)
        defer { session.invalidateAndCancel() }
        var request = try URLRequest(url: #require(URL(string: "http://127.0.0.1:\(listener.port)/body")))
        request.httpMethod = "POST"
        request.httpBodyStream = InputStream(data: Data("stream".utf8))
        let task = session.dataTask(with: request)
        task.resume()

        #expect(await d02Eventually { delegate.outcome.withLock { $0.completed } })
        #expect(D02RejectingProtocol.observations.withLock { $0.bodyStreams } == [true])
        #expect(delegate.outcome.withLock { $0.errorDomain } == D02RejectingProtocol.errorDomain)
        listener.poll()
        #expect(listener.connections == 0)
    }
}
