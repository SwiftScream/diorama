import DioramaCore
import Synchronization
import Testing

struct PurePassthroughTests {
    private final class Resource: Sendable {
        let release: @Sendable () -> Void

        init(release: @escaping @Sendable () -> Void) {
            self.release = release
        }

        deinit { release() }
    }

    private enum Failure: Error { case construction }

    private func system(
        _ name: String,
        factory: @escaping @Sendable () throws -> Resource,
        cleanup: @escaping @Sendable () throws -> Void = {}) throws -> ScenarioSystem<Resource>
    {
        let type = ScenarioSystemType("test.pure-passthrough")
        let id = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: name))
        var attachment = ScenarioAttachment(id: id)
        for key in ["first", "second"] {
            let track = TrackID(attachmentID: id, key: TrackKey(rawValue: key))
            attachment = try attachment.adding(SequentialTrack(
                id: track, header: ValuePreparation<String>().admitPrepared("baseline"),
                values: [ValuePreparation<Int>().admitPrepared(7)]))
        }
        return try ScenarioSystem(type: type, attachment: attachment) { context in
            #expect(context.mode == .passthrough)
            return PreparedSystem { try ActivatedSystem(dependency: factory(), deactivate: cleanup) }
        }
    }

    @Test
    func `passthrough needs no leases and preserves headered content and ordered usage`() async throws {
        let factories = Mutex(0)
        let releases = Mutex(0)
        let cleanups = Mutex(0)
        let system = try system("live", factory: {
            factories.withLock { $0 += 1 }
            return Resource { releases.withLock { $0 += 1 } }
        }, cleanup: { cleanups.withLock { $0 += 1 } })
        let execution = try ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [system.attachment]),
            scenarioID: ScenarioID(rawValue: "native"), defaultMode: .passthrough,
            systems: [AnyScenarioSystem(system)])
        #expect(factories.withLock { $0 } == 1)
        let result = await execution.finish()
        #expect(releases.withLock { $0 } == 1)
        #expect(cleanups.withLock { $0 } == 0)
        #expect(result.report.diagnostics.isEmpty)
        #expect(result.usage[0].tracks.map(\.id) == system.attachment.trackIDs)
        #expect(result.usage[0].tracks.allSatisfy {
            $0.activity == .passthrough && $0.claimedRecords.isEmpty && $0.unclaimedRecords.isEmpty
        })
        let final = try #require(result.definition?.attachments.first)
        for id in final.trackIDs {
            let track = try #require(try final.track(id, as: Int.self, header: String.self))
            #expect(track.header == "baseline")
            #expect(track.records.map(\.value) == [7])
        }
    }

    @Test
    func `later startup failure releases prior native dependencies and factory cleans partial construction`() throws {
        let releases = Mutex(0)
        let partialCleanups = Mutex(0)
        let first = try system("first", factory: {
            Resource { releases.withLock { $0 += 1 } }
        }, cleanup: { Issue.record("Core must not invoke managed cleanup on passthrough") })
        let second = try system("second", factory: {
            let partial = Resource { releases.withLock { $0 += 1 } }
            defer {
                partialCleanups.withLock { $0 += 1 }
                withExtendedLifetime(partial) {}
            }
            throw Failure.construction
        })
        #expect(throws: ScenarioStartupFailure.self) {
            _ = try ScenarioExecution.start(
                definition: ScenarioDefinition(attachments: [first.attachment, second.attachment]),
                scenarioID: ScenarioID(rawValue: "rollback"), defaultMode: .passthrough,
                systems: [AnyScenarioSystem(first), AnyScenarioSystem(second)])
        }
        #expect(releases.withLock { $0 } == 2)
        #expect(partialCleanups.withLock { $0 } == 1)
    }

    @Test
    func `passthrough rejects lease construction before policies and activation`() throws {
        let system = try system("layout", factory: { Resource {} })
        let invalid = try ScenarioSystem(type: system.type, attachment: system.attachment) { context in
            let lease = try context.lease(
                for: system.attachment.trackIDs[0],
                preparation: ValuePreparation<Int>(validate: { _ in Issue.record("Content policy ran") }),
                headerPreparation: ValuePreparation<String>(validate: { _ in Issue.record("Header policy ran") }))
            return PreparedSystem {
                Issue.record("Invalid lease request activated")
                return ActivatedSystem(dependency: lease, deactivate: {})
            }
        }
        #expect(throws: ScenarioStartupFailure.self) {
            _ = try ScenarioExecution.start(
                definition: ScenarioDefinition(attachments: [invalid.attachment]),
                scenarioID: ScenarioID(rawValue: "no-leases"), defaultMode: .passthrough,
                systems: [AnyScenarioSystem(invalid)])
        }
    }
}
