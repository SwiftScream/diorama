import Diorama
import DioramaCore
import DioramaDate
import DioramaPersistence
import Foundation
import Synchronization
import Testing

private enum InvalidWall: CaseIterable, Sendable {
    case nonfinite, missingHeader, invalidOffset, submillisecond, emptyWithHeader

    var content: (header: Int?, values: [OverridableValue<Date>]) {
        switch self {
        case .nonfinite: (0, [.observed(Date(timeIntervalSince1970: .infinity))])
        case .missingHeader: (nil, [.observed(Date(timeIntervalSince1970: 1))])
        case .invalidOffset: (2000, [.observed(Date(timeIntervalSince1970: 1))])
        case .submillisecond: (0, [.observed(Date(timeIntervalSince1970: 0.0004))])
        case .emptyWithHeader: (0, [])
        }
    }
}

private final class AdmissionProbe: Sendable {
    let events = Mutex<[String]>([])

    func source() -> AdmissionDateSource {
        events.withLock { $0.append("date-source") }
        return AdmissionDateSource()
    }
}

private struct AdmissionDateSource: DioramaDateSource {
    var now: Date {
        Date(timeIntervalSince1970: 42)
    }
}

private struct EarlierDefinition: SystemDefinition {
    let systemType = ScenarioSystemType("consumer.admission-order")
    let probe: AdmissionProbe

    func makeRecordState(in _: borrowing SystemStateContext) {
        probe.events.withLock { $0.append("earlier-state") }
    }

    func makeReplayState(in context: borrowing SystemStateContext) {
        makeRecordState(in: context)
    }

    func makeRecordDependency(using _: SystemExecution<Void>) -> Int {
        probe.events.withLock { $0.append("earlier-dependency") }
        return 1
    }

    func makeReplayDependency(using execution: SystemExecution<Void>) -> Int {
        makeRecordDependency(using: execution)
    }

    func makePassthroughDependency(using _: SystemExecution<Void>) -> Int {
        1
    }
}

struct WholeTrackAdmissionTests {
    @Test(arguments: InvalidWall.allCases, [ScenarioMode.record, .replay])
    private func `malformed no op prepared Date tracks reject all activation`(
        invalid: InvalidWall, mode: ScenarioMode) async throws
    {
        let probe = AdmissionProbe()
        let first = try ScenarioSystem(named: "first", definition: EarlierDefinition(probe: probe))
        let wall = try DioramaDateSystem.instance(named: "wall") { probe.source() }
        let malformed = try attachment(wall, header: invalid.content.header, values: invalid.content.values)
        let baseline = try ScenarioDefinition(attachments: [first.attachment, malformed])
        do {
            _ = try await ScenarioExecution.start(
                definition: baseline, scenarioID: .init(rawValue: "admission"),
                defaultMode: mode, systems: [AnyScenarioSystem(first), AnyScenarioSystem(wall)])
            Issue.record("Malformed Date content activated")
        } catch {
            assertRejected(error.report, track: malformed.trackIDs[0])
        }
        // The reusable setup contributes a valid empty track; the fixed loaded
        // definition is authoritative and must be rejected in the facade too.
        let setup = try Diorama(definition: baseline, scenarioID: "admission", mode: mode, systems: first, wall)
        do {
            _ = try await setup.execute { _, _, _ in Issue.record("Invalid baseline entered body") }
            Issue.record("Malformed resolved Date content activated")
        } catch let failure as ScenarioStartupFailure {
            assertRejected(failure.report, track: malformed.trackIDs[0])
        }
        #expect(probe.events.withLock { $0.isEmpty })
    }

    @Test(arguments: InvalidWall.allCases, [ScenarioMode.record, .replay])
    private func `repository loaded content is validated independently of the codec`(
        invalid: InvalidWall, mode: ScenarioMode) async throws
    {
        let probe = AdmissionProbe()
        let wall = try DioramaDateSystem.instance(named: "wall") { probe.source() }
        let malformed = try attachment(wall, header: invalid.content.header, values: invalid.content.values)
        // A deliberately permissive public test codec supplies a loaded typed
        // baseline. The real Date codec rejects these structures sooner.
        let registration = ScenarioSystemType(id: DioramaDateSystem.type.id, persistence: PersistentSystemRegistration(
            currentSchemaVersion: 1, payloadType: Int.self, encode: { _ in 1 }, decode: { _, _ in malformed }))
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([registration]))
        let bytes = try codec.encode(ScenarioDefinition(attachments: [malformed]))
        let storage = AdmissionStorage(bytes: bytes)
        let repository = JSONScenarioRepository(codec: codec, storage: storage)
        do {
            _ = try await Diorama(repository: repository, scenarioID: "loaded", mode: mode, systems: wall)
                .execute { _, _ in Issue.record("Malformed loaded content entered body") }
            Issue.record("Malformed loaded content activated")
        } catch let failure as ScenarioRepositoryStartupFailure {
            guard case .load(.loaded) = failure.evidence else {
                Issue.record("Expected loaded content to reach Date's runtime admission"); return
            }
            assertRejected(failure.startupFailure.report, track: malformed.trackIDs[0])
        }
        #expect(probe.events.withLock { $0.isEmpty })
        #expect(storage.reads.withLock { $0 } == 1)
        #expect(storage.writes.withLock { $0 } == 0)
    }

    @Test(arguments: [ScenarioMode.record, .replay])
    func `valid empty repeated backward authored and boundary tracks retain strict meaning`(mode: ScenarioMode)
        async throws
    {
        let cases: [(Int?, [OverridableValue<Date>])] = [
            (nil, []),
            (0, [0, 0, -1, 2].map { .observed(Date(timeIntervalSince1970: $0)) }),
            (840, [
                .override(Date(timeIntervalSince1970: -62_135_500_000)),
                .observed(Date(timeIntervalSince1970: 253_402_250_000)),
                .override(Date(timeIntervalSince1970: -62_135_500_000)),
            ]),
            (-840, [.observed(Date(timeIntervalSince1970: 253_402_250_000))]),
        ]
        for (header, values) in cases {
            let probe = AdmissionProbe()
            let wall = try DioramaDateSystem.instance(named: "wall") { probe.source() }
            let original = try attachment(wall, header: header, values: values)
            let definition = try ScenarioDefinition(attachments: [original])
            let result = try await Diorama(definition: definition, scenarioID: "valid", mode: mode, systems: wall)
                .execute { _, source in
                    if mode == .replay {
                        #expect(values.map { _ in source.now } == values.map(\.value))
                    }
                }
            #expect(result.report.finalization.report.diagnostics.isEmpty)
            #expect(result.definition != nil)
            let track = try #require(try original.track(original.trackIDs[0],
                                                        as: OverridableValue<Date>.self, header: Int?.self))
            #expect(track.header == header)
            #expect(track.records.map(\.value) == values)
            #expect(probe.events.withLock { $0.count } == (mode == .record ? 1 : 0))
            if mode == .replay {
                #expect(result.report.evaluated(.allRecordsClaimed).isSatisfied)
                #expect(result.report.evaluated(.allClaimedRecordsConsumed).isSatisfied)
            }
        }
    }

    @Test(arguments: InvalidWall.allCases)
    private func `passthrough bypasses runtime content checks while the first party codec stays strict`(
        invalid: InvalidWall) async throws
    {
        let probe = AdmissionProbe()
        let wall = try DioramaDateSystem.instance(named: "wall") { probe.source() }
        let malformed = try attachment(wall, header: invalid.content.header, values: invalid.content.values)
        let execution = try await ScenarioExecution.start(
            definition: ScenarioDefinition(attachments: [malformed]),
            scenarioID: .init(rawValue: "pass"), defaultMode: .passthrough,
            systems: [AnyScenarioSystem(wall)])
        let source = try execution.dependency(wall)
        #expect(source.now == Date(timeIntervalSince1970: 42))
        let final = await execution.finish()
        #expect(final.report.diagnostics.isEmpty)
        #expect(source.now == Date(timeIntervalSince1970: 42))
        #expect(execution.reporter.postFinishDiagnostics.isEmpty)
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([DioramaDateSystem.type]))
        #expect(throws: (any Error).self) { try codec.encode(ScenarioDefinition(attachments: [malformed])) }
    }

    @Test func `strict file decoding rejects a malformed origin before replay activation`() async throws {
        let text = try #require(String(data: DateConformanceSupport.fixture("date-nonempty"), encoding: .utf8))
        let malformed = Data(text.replacingOccurrences(of: "+11:00", with: "+33:20").utf8)
        #expect(malformed != Data(text.utf8))
        let storage = AdmissionStorage(bytes: malformed)
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([DioramaDateSystem.type]))
        #expect(throws: (any Error).self) { try codec.decode(malformed) }
        let probe = AdmissionProbe()
        let wall = try DioramaDateSystem.instance(named: "clock") { probe.source() }
        do {
            _ = try await Diorama(repository: JSONScenarioRepository(codec: codec, storage: storage),
                                  scenarioID: "decoder", mode: .replay, systems: wall).execute { _, _ in () }
            Issue.record("Invalid persisted origin activated")
        } catch let failure as ScenarioRepositoryStartupFailure {
            guard case .load(.invalidDocument) = failure.evidence else {
                Issue.record("Expected decoder failure before runtime admission"); return
            }
        }
        #expect(probe.events.withLock { $0.isEmpty })
        #expect(storage.writes.withLock { $0 } == 0)
    }

    private func attachment(_ system: ScenarioSystem<any DioramaDateSource>,
                            header: Int?, values: [OverridableValue<Date>]) throws -> ScenarioAttachment
    {
        let prepared = try values.map { try ValuePreparation<OverridableValue<Date>>().admitPrepared($0) }
        let track = try SequentialTrack(id: #require(system.attachment.trackIDs.first),
                                        header: ValuePreparation<Int?>().admitPrepared(header), values: prepared)
        return try ScenarioAttachment(id: system.attachment.id).adding(track)
    }

    private func assertRejected(_ report: DiagnosticReport, track: TrackID) {
        #expect(report.diagnostics.contains {
            $0.diagnostic.issue == .preparationFailed(.validation) && $0.diagnostic.context.trackID == track
        })
        #expect(report.diagnostics.contains {
            $0.diagnostic.issue == .lifecycle(.preparationFailed)
                && $0.diagnostic.context == .attachment(track.attachmentID)
        })
    }
}

private final class AdmissionStorage: ScenarioDocumentStorage, Sendable {
    let bytes: Data
    let reads = Mutex(0)
    let writes = Mutex(0)
    init(bytes: Data) {
        self.bytes = bytes
    }

    func load() -> Data? {
        reads.withLock { $0 += 1 }; return bytes
    }

    func publish(_: Data) -> DocumentPublication {
        writes.withLock { $0 += 1 }; return DocumentPublication()
    }
}
