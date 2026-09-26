import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Synchronization
import Testing

extension D05ReplayTests {
    @Test(arguments: [1, 4])
    func `quiescence drains callbacks queued before admission closes`(width: Int) async throws {
        let observer = D05NativeObserver()
        let session = d05ReplaySession(observer, width: width)
        defer {
            session.delegateQueue.isSuspended = false
            session.invalidateAndCancel()
            D05ReplayProtocol.operations.withLock { $0 = [:] }
        }
        let task = try session.dataTask(with: #require(URL(string: "http://d05.invalid/queued")))
        task.resume()
        try #require(await d02Eventually { D05ReplayProtocol.operations.withLock { !$0.isEmpty } })
        let operation = try #require(D05ReplayProtocol.operations.withLock { $0.values.first })
        session.delegateQueue.isSuspended = true
        operation.delivery.head()
        try #require(await d02Eventually { session.delegateQueue.operationCount > 0 })
        let returned = Mutex(false)
        let closer = Task {
            let result = await d05CloseReplay(session, observer: observer)
            returned.withLock { $0 = true }
            return result
        }
        try #require(await d02Eventually { operation.stopped.withLock { $0 } })
        #expect(!returned.withLock { $0 })
        session.delegateQueue.isSuspended = false
        #expect(await closer.value)
        #expect(task.state == .completed)
        #expect(observer.events.withLock { $0.completions } == 1)
        #expect(observer.events.withLock { $0.invalidated })
        #expect(!operation.delivery.bytes("late"))
    }
}
