import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing

extension D05ReplayTests {
    @Test
    func `cancellation races terminal delivery on a serial native queue`() async throws {
        for _ in 0..<50 {
            let session = try await raceOnce(width: 1)
            try #require(await d02Eventually { session.isReleased })
        }
    }

    @Test(.enabled(if: d05CanRaceConcurrentQueue, "FN-10: concurrent completion can remove a task twice"))
    func `cancellation races terminal delivery on a concurrent native queue`() async throws {
        for _ in 0..<50 {
            let session = try await raceOnce(width: 4)
            try #require(await d02Eventually { session.isReleased })
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIORAMA_D05_STRESS_SERIAL"] == "1"))
    func `extended serial queue registry audit`() async throws {
        for _ in 0..<1000 {
            let session = try await raceOnce(width: 1)
            try #require(await d02Eventually { session.isReleased })
        }
    }

    private func raceOnce(width: Int) async throws -> D05WeakObject<URLSession> {
        let observer = D05NativeObserver()
        let session = d05ReplaySession(observer, width: width)
        defer { session.invalidateAndCancel(); D05ReplayProtocol.operations.withLock { $0 = [:] } }
        let task = session.dataTask(with: URL(string: "http://d05.invalid/race")!) { data, _, error in
            observer.complete(data: data, error: error)
        }
        task.resume()
        try #require(await d02Eventually { D05ReplayProtocol.operations.withLock { !$0.isEmpty } })
        let operation = try #require(D05ReplayProtocol.operations.withLock { $0.values.first })
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                operation.delivery.head()
                operation.delivery.bytes("race")
                operation.delivery.finish()
            }
            group.addTask { task.cancel() }
            await group.waitForAll()
        }
        session.finishTasksAndInvalidate()
        try #require(await d02Eventually { observer.events.withLock { $0.invalidated } })
        await d05QueueBarrier(session.delegateQueue)
        #expect(observer.events.withLock { $0.completions } == 1)
        let result = observer.events.withLock { $0 }
        if result.errorCode == nil {
            #expect(result.body == Data("race".utf8))
        } else {
            #expect(result.errorCode == URLError.cancelled.rawValue)
        }
        #expect(task.state == .completed)
        #expect(!operation.delivery.bytes("after-terminal"))
        return D05WeakObject(session)
    }
}

private let d05CanRaceConcurrentQueue: Bool = {
    #if canImport(FoundationNetworking)
        ProcessInfo.processInfo.environment["DIORAMA_D05_UNSAFE_TERMINAL_RACE"] == "1" ||
            ProcessInfo.processInfo.environment["DIORAMA_VERIFY_FOUNDATION_FIXES"] == "1"
    #else
        true
    #endif
}()
