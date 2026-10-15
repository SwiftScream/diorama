import DioramaCore
import Synchronization
import Testing

private final class TrackLookupJournal: Sendable {
    let admissions = Mutex(0)
    let activations = Mutex(0)
}

private struct TrackLookupDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.track-lookup")
    let values: TrackDefinition<Int, String>
    let lookup: TrackDefinition<Int, String>
    let journal = TrackLookupJournal()
    var duplicate: AnyTrackDefinition?
    var invalid: TrackDefinitionLookupTests.InvalidLookup?
    var failDuringActivation = false

    init() throws {
        let journal = journal
        values = try TrackDefinition(
            "values", header: ValuePreparation<String>().admitPrepared("registered"),
            values: [ValuePreparation<Int>().admitPrepared(7)],
            preparation: ValuePreparation(validate: { _ in journal.admissions.withLock { $0 += 1 } }),
            headerPreparation: ValuePreparation(validate: { _ in journal.admissions.withLock { $0 += 1 } }),
            continuationPolicy: .fallback(-1))
        lookup = try TrackDefinition(
            "values", header: ValuePreparation<String>().admitPrepared("lookup"),
            values: [ValuePreparation<Int>().admitPrepared(99)],
            preparation: ValuePreparation(validate: { _ in Issue.record("Lookup value policy ran") }),
            headerPreparation: ValuePreparation(validate: { _ in Issue.record("Lookup header policy ran") }),
            continuationPolicy: .fallback(-99))
    }

    var tracks: [AnyTrackDefinition] {
        if let duplicate {
            [values.erased, duplicate]
        } else {
            [values.erased]
        }
    }

    func validate(in context: borrowing SystemValidationContext) throws {
        if let invalid, !failDuringActivation {
            switch invalid {
            case .missingKey:
                _ = try context.track(TrackDefinition<Int, String>(
                    "missing", header: ValuePreparation<String>().admitPrepared("unused")))
            case .valueType:
                _ = try context.track(TrackDefinition<String, String>(
                    "values", header: ValuePreparation<String>().admitPrepared("unused")))
            case .headerType:
                _ = try context.track(TrackDefinition<Int, Void>("values"))
            }
        }
        let registered = try context.track(values)
        let found = try context.track(lookup)
        #expect(found.id.attachmentID == context.attachmentID)
        #expect(found.header == registered.header)
        #expect(found.records == registered.records)
    }

    var record: SystemModeDefinition<SequentialTrackLease<Int, String>, SequentialTrackLease<Int, String>> {
        .init(makeState: makeRecordState, makeDependency: makeRecordDependency)
    }

    var replay: SystemModeDefinition<SequentialTrackLease<Int, String>, SequentialTrackLease<Int, String>> {
        .init(makeState: makeReplayState, makeDependency: makeReplayDependency)
    }

    var passthrough: SystemModeDefinition<Void, SequentialTrackLease<Int, String>> {
        .init(makeDependency: makePassthroughDependency)
    }

    func makeRecordState(in context: borrowing SystemStateContext) throws
        -> SequentialTrackLease<Int, String>
    {
        journal.activations.withLock { $0 += 1 }
        if let invalid, failDuringActivation {
            switch invalid {
            case .missingKey:
                _ = try context.lease(for: TrackDefinition<Int, String>(
                    "missing", header: ValuePreparation<String>().admitPrepared("unused")))
            case .valueType:
                _ = try context.lease(for: TrackDefinition<String, String>(
                    "values", header: ValuePreparation<String>().admitPrepared("unused")))
            case .headerType:
                _ = try context.lease(for: TrackDefinition<Int, Void>("values"))
            }
        }
        let registered = try context.track(values)
        let found = try context.track(lookup)
        #expect(found.header == registered.header)
        #expect(found.records == registered.records)
        let lease = try context.lease(for: lookup)
        #expect(try lease === context.lease(for: values))
        #expect(try lease === context.lease(for: lookup))
        return lease
    }

    func makeReplayState(in context: borrowing SystemStateContext) throws
        -> SequentialTrackLease<Int, String>
    {
        try makeRecordState(in: context)
    }

    func makeRecordDependency(using execution: SystemExecution<SequentialTrackLease<Int, String>>)
        throws -> SequentialTrackLease<Int, String>
    {
        try execution.state.withLock { lease, _ in lease }
    }

    func makeReplayDependency(using execution: SystemExecution<SequentialTrackLease<Int, String>>)
        throws -> SequentialTrackLease<Int, String>
    {
        try makeRecordDependency(using: execution)
    }

    func makePassthroughDependency(using _: SystemExecution<Void>) throws -> SequentialTrackLease<Int, String> {
        throw CancellationError()
    }
}

struct TrackDefinitionLookupTests {
    enum Duplicate: CaseIterable {
        case sameTypes, differentValueType, differentHeaderType
    }

    enum InvalidLookup: CaseIterable {
        case missingKey, valueType, headerType
    }

    @Test(arguments: Duplicate.allCases)
    func `separate definitions with duplicate keys fail setup`(_ duplicate: Duplicate) throws {
        var definition = try TrackLookupDefinition()
        switch duplicate {
        case .sameTypes:
            definition.duplicate = definition.lookup.erased
        case .differentValueType:
            definition.duplicate = try TrackDefinition<String, String>(
                "values", header: ValuePreparation<String>().admitPrepared("unused")).erased
        case .differentHeaderType:
            definition.duplicate = TrackDefinition<Int, Void>("values").erased
        }
        let attachmentID = AttachmentID(systemTypeID: definition.systemType.id, key: .init(rawValue: "counter"))
        let trackID = TrackID(attachmentID: attachmentID, key: .init(rawValue: "values"))
        #expect(throws: ScenarioDefinitionError.duplicateTrack(trackID)) {
            try ScenarioSystem(named: "counter", definition: definition)
        }
        #expect(definition.journal.admissions.withLock { $0 } == 0)
        #expect(definition.journal.activations.withLock { $0 } == 0)
    }

    @Test func `same key lookup uses registered policies and independent prepared leases`() async throws {
        let definition = try TrackLookupDefinition()
        let first = try ScenarioSystem(named: "first", definition: definition)
        let second = try ScenarioSystem(named: "second", definition: definition)
        let loadedFirst = try ScenarioAttachment(id: first.attachment.id).adding(SequentialTrack(
            id: first.attachment.trackIDs[0], header: ValuePreparation<String>().admitPrepared("loaded"),
            values: [ValuePreparation<Int>().admitPrepared(9)]))
        let baseline = try ScenarioDefinition(attachments: [loadedFirst, second.attachment])
        var previous: SequentialTrackLease<Int, String>?
        for run in 1...2 {
            let execution = try await ScenarioExecution.start(
                definition: baseline, scenarioID: .init(rawValue: "track-lookup"), defaultMode: .replay,
                systems: [AnyScenarioSystem(first), AnyScenarioSystem(second)])
            let firstLease = try execution.dependency(first)
            let secondLease = try execution.dependency(second)
            #expect(firstLease !== secondLease)
            if let previous {
                #expect(firstLease !== previous)
            }
            #expect(try firstLease.consumeNext() == 9)
            #expect(try secondLease.consumeNext() == 7)
            #expect(try firstLease.consumeNext() == -1)
            #expect(try secondLease.consumeNext() == -1)
            #expect(definition.journal.admissions.withLock { $0 } == 4 * run)
            #expect(definition.journal.activations.withLock { $0 } == 2 * run)
            _ = await execution.finish()
            previous = firstLease
        }
    }

    @Test(arguments: InvalidLookup.allCases, [false, true])
    func `missing keys and incompatible types reject lookup`(
        _ invalid: InvalidLookup, duringActivation: Bool) async throws
    {
        var definition = try TrackLookupDefinition()
        definition.invalid = invalid
        definition.failDuringActivation = duringActivation
        let system = try ScenarioSystem(named: "counter", definition: definition)
        let key = invalid == .missingKey ? "missing" : "values"
        let trackID = TrackID(attachmentID: system.attachment.id, key: .init(rawValue: key))
        do {
            let execution = try await ScenarioExecution.start(
                definition: ScenarioDefinition(attachments: [system.attachment]),
                scenarioID: .init(rawValue: "track-lookup"), defaultMode: .replay,
                systems: [AnyScenarioSystem(system)])
            _ = await execution.finish()
            Issue.record("Invalid track lookup succeeded")
        } catch let failure as ScenarioStartupFailure {
            #expect(failure.report.diagnostics.contains {
                $0.diagnostic.issue == .lifecycle(.invalidTrackRequest) && $0.diagnostic.context == .track(trackID)
            })
        }
        #expect(definition.journal.activations.withLock { $0 } == (duringActivation ? 1 : 0))
    }
}
