import DioramaCore
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ReplayContinuationConcurrencyTests {
    @Test
    func `concurrent exhausted reads always repeat the final consumed value`() async throws {
        let values = Array((1...80).reversed())
        let (execution, lease) = try ReplayContinuationFixtures.start(
            values: values, policy: .replayLast(defaultValue: -1))
        let returned = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<100 {
                group.addTask { try lease.consumeNext() }
            }
            var returned: [Int] = []
            for try await value in group {
                returned.append(value)
            }
            return returned
        }
        #expect(returned.sorted() == (values + Array(repeating: 1, count: 20)).sorted())
        let result = await execution.finish()
        #expect(result.usage[0].tracks[0].claimedRecords.count == 80)
        #expect(!result.usage[0].tracks[0].claimedRecords.contains { !$0.isConsumed })
        #expect(result.report.diagnostics.count == 20)
        #expect(try lease.consumeNext() == 1)
    }

    @Test
    func `repeated continuations retain one diagnostic per call for the final report`() async throws {
        let (execution, lease) = try ReplayContinuationFixtures.start(
            values: [7], policy: .replayLast(defaultValue: -1))
        #expect(try lease.consumeNext() == 7)
        #expect(try lease.consumeNext() == 7)
        #expect(try lease.consumeNext() == 7)
        #expect(execution.reporter.report == nil)
        let result = await execution.finish()
        #expect(result.report.diagnostics.count == 2)
        #expect(result.report.diagnostics.allSatisfy {
            $0.diagnostic.issue == .sequential(.replayExhausted(availableCount: 1))
        })
    }

    @Test
    func `finish racing reads freezes continuation at the last consumed position`() async throws {
        let values = Array((1...80).reversed())
        let (execution, lease) = try ReplayContinuationFixtures.start(
            values: values, policy: .replayLast(defaultValue: -1))
        #expect(try lease.consumeNext() == 80)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = await execution.finish() }
            for _ in 0..<100 {
                group.addTask { _ = try lease.consumeNext() }
            }
            try await group.waitForAll()
        }
        let result = await execution.finish()
        let consumed = result.usage[0].tracks[0].claimedRecords.count
        #expect(consumed >= 1)
        #expect(try lease.consumeNext() == values[consumed - 1])
        #expect(await execution.finish().usage == result.usage)
        #expect(execution.reporter.postFinishDiagnostics.last?.diagnostic.issue == .lifecycle(.leaseClosed))
    }
}
