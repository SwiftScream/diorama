import Diorama
import DioramaCore
import DioramaPersistence
import Dispatch
import Testing

/// A synchronous storage gate occupies one worker while the observer suspends.
@Suite(.serialized)
struct DioramaPublicationLifetimeTests {
    @Test
    func `completed report does not retain repository storage`() async throws {
        weak var releasedStorage: PublicationStorage?
        let report: DioramaReport
        do {
            let storage = PublicationStorage()
            releasedStorage = storage
            let system = try StartupProbe().system(key: "record")
            let result = try await Diorama(repository: randomRepository(storage: storage),
                                           scenarioID: "lifetime", mode: .record,
                                           systems: system).execute { _, _ in }
            report = result.report
        }
        #expect(releasedStorage == nil)
        #expect(report.publication.disposition == .published)
        #expect(report.rendered().contains("scenario=\"lifetime\""))
    }

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
            try await setup.execute { _, lease in
                try lease.record(capturing: { 42 }, preparation: ValuePreparation<UInt64>())
                return 123
            }
        }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        #expect(storage.document == nil)
        #expect(setup.report == nil)
        await #expect(throws: DioramaExecutionError.executionAlreadyInProgress) {
            try await setup.execute { _, _ in Issue.record("An overlapping publication was admitted") }
        }
        #expect(storage.readCount == 1)
        release.signal()

        let result = try await task.value
        #expect(result.body == 123)
        #expect(setup.report == result.report)
        #expect(try PublicationFixtures.values("record", in: #require(result.definition)) == [42])
        if fail {
            guard case .failed(.storage) = result.publication else {
                Issue.record("Expected storage failure"); return
            }
        } else {
            guard case .published = result.publication else { Issue.record("Expected publication"); return }
        }
        #expect(result.report.publication.disposition == (fail ? .failed : .published))
        #expect(result.report.publication.candidate.isComplete)
        #expect(result.report.publication.priorDocument == .absent)
        #expect(storage.writeCount == 1)
        #expect(storage.readCount == 1)
        #expect((storage.document == nil) == fail)
    }

    @Test
    func `publication failure remains visible alongside the original body error`() async throws {
        let storage = PublicationStorage(beforeCommit: { throw PublicationFixtures.Failure.storage })
        let system = try StartupProbe().system(key: "record")
        let setup = try Diorama(repository: randomRepository(storage: storage),
                                scenarioID: "both-failed", mode: .record, systems: system)
        do {
            _ = try await setup.execute { _, lease in
                try lease.record(capturing: { 42 }, preparation: ValuePreparation<UInt64>())
                throw PublicationFixtures.Failure.body
            }
            Issue.record("Expected the original body error")
        } catch {
            #expect(error as? PublicationFixtures.Failure == .body)
            let report = try #require(setup.report)
            #expect(report.publication.disposition == .failed)
            #expect(report.publication.candidate.isComplete)
            #expect(report.publication.issues.map(\.stage) == [.storage(nil)])
            #expect(storage.writeCount == 1)
        }
        let next = try await setup.execute { _, _ in 7 }
        #expect(next.body == 7)
        #expect(setup.report == next.report)
        #expect(storage.writeCount == 2)
    }
}
