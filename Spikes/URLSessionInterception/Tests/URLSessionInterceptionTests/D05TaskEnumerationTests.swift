import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

extension D05ReplayTests {
    @Test(.enabled(if: d05AuditTaskEnumeration, "FN-19: enumeration can race native registry mutation"),
          arguments: [1, 4])
    func `task enumeration overlaps native completion`(width: Int) async throws {
        for _ in 0..<20 {
            try await enumerateDuringCompletion(width: width)
        }
    }

    private func enumerateDuringCompletion(width: Int) async throws {
        let observer = D05NativeObserver()
        let session = d05ReplaySession(observer, width: width)
        defer { session.invalidateAndCancel(); D05ReplayProtocol.operations.withLock { $0 = [:] } }
        let url = try #require(URL(string: "http://d05.invalid/enumeration"))
        for _ in 0..<32 {
            session.dataTask(with: url) { data, _, error in
                observer.complete(data: data, error: error)
            }.resume()
        }
        try #require(await d02Eventually { D05ReplayProtocol.operations.withLock { $0.count == 32 } })
        let operations = D05ReplayProtocol.operations.withLock { Array($0.values) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<64 {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        session.getAllTasks { _ in continuation.resume() }
                    }
                }
            }
            group.addTask {
                for operation in operations {
                    operation.delivery.head()
                    operation.delivery.bytes("done")
                    operation.delivery.finish()
                }
            }
        }
        session.finishTasksAndInvalidate()
        try #require(await d02Eventually { observer.events.withLock { $0.invalidated } })
        await d05QueueBarrier(session.delegateQueue)
        #expect(observer.events.withLock { $0.completions } == 32)
        #expect(operations.allSatisfy { $0.task.state == .completed })
    }
}

private let d05AuditTaskEnumeration =
    ProcessInfo.processInfo.environment["DIORAMA_D05_TASK_ENUMERATION_STRESS"] == "1" ||
    ProcessInfo.processInfo.environment["DIORAMA_VERIFY_FOUNDATION_FIXES"] == "1"
