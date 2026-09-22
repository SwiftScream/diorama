import Diorama
import DioramaCore
import DioramaPersistence
import Dispatch
import Testing

/// A synchronous storage gate occupies one worker while the observer suspends.
@Suite(.serialized)
struct DioramaPublicationLifetimeTests {
    @Test(arguments: [false, true])
    func `canceled scoped caller completes its one publication attempt`(fail: Bool) async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let storage = PublicationStorage(beforeCommit: {
            entered.continuation.yield(())
            #expect(release.wait(timeout: .now() + 10) == .success)
            if fail {
                throw PublicationFixtures.Failure.storage
            }
        })
        let system = try StartupProbe().system(key: "record")
        let setup = try Diorama(repository: randomRepository(storage: storage),
                                scenarioID: "once", mode: .record, systems: system)
        let task = Task {
            try await setup.execute { lease in
                try lease.append(capturing: { 42 }, preparation: ValuePreparation<UInt64>())
                return 123
            }
        }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        #expect(storage.document == nil)
        release.signal()

        let result = try await task.value
        #expect(result.body == 123)
        #expect(try PublicationFixtures.values("record", in: #require(result.definition)) == [42])
        if fail {
            guard case .failed(.storage) = result.publication else {
                Issue.record("Expected storage failure"); return
            }
        } else {
            guard case .published = result.publication else { Issue.record("Expected publication"); return }
        }
        #expect(storage.writeCount == 1)
        #expect(storage.readCount == 1)
        #expect((storage.document == nil) == fail)
    }
}
