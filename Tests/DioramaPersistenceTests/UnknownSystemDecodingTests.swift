import Diorama
import DioramaCore
import DioramaPersistence
@testable import DioramaRandom
import Foundation
import Testing

struct UnknownSystemDecodingTests {
    @Test(arguments: ["null", "[true, 42, {\"future\": false}]", "{\"unrecognized\": \"data\"}"])
    func `strict decoding rejects unknown types while startup retains their headers`(payload: String) async throws {
        let bytes = document([
            entry("active"),
            entry("inactive", type: "future.system", version: 999, payload: payload),
        ])
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry([DioramaRandomSystem.type]))
        #expect(throws: PersistenceDispatchError.unknownSystemType(SystemTypeID(rawValue: "future.system"))) {
            try codec.decode(bytes)
        }
        let storage = StartupStorage(document: bytes)
        let repository = try randomRepository(storage: storage)
        guard case .incompatibleSystem = repository.load() else {
            Issue.record("Standalone load must remain strict"); return
        }
        let probe = StartupProbe()
        let system = try probe.system(key: "active")
        let setup = try Diorama(repository: repository, scenarioID: "unknown-types",
                                mode: .replay, systems: system)
        let result = try await setup.execute { lease in try lease.claimNext().value }
        #expect(result.body == 7)
        guard case let .loaded(definition, skipped) = result.loadResult else {
            Issue.record("Missing loaded content and omission evidence"); return
        }
        #expect(definition.attachments.map(\.id.key.rawValue) == ["active"])
        #expect(skipped == [
            PersistedSystemDescriptor(
                attachmentKey: AttachmentKey(rawValue: "inactive"),
                systemTypeID: SystemTypeID(rawValue: "future.system"), schemaVersion: 999),
        ])
        #expect(result.finalization.report.diagnostics.map(\.diagnostic.issue) == [
            .baseline(.loadedAttachmentNotConfigured),
        ])
        #expect(try codec.decode(codec.encode(definition)).attachments.count == 1)
        #expect(storage.readCount == 2)
        #expect(storage.writeCount == 0)
        #expect(probe.activationCount == 1)
    }

    @Test(arguments: [ScenarioMode.replay, .record, .passthrough])
    func `an unknown type at an active key follows incompatible baseline policy`(mode: ScenarioMode) async throws {
        let storage = StartupStorage(document: document([entry("active", type: "future.system")]))
        let repository = try randomRepository(storage: storage)
        let probe = StartupProbe()
        let system = try probe.system(key: "active")
        let setup = try Diorama(repository: repository, scenarioID: "unknown-types", mode: mode, systems: system)
        if mode == .replay {
            do {
                _ = try await setup.execute { _ in () }
                Issue.record("Incompatible active type started replay")
            } catch let failure as ScenarioRepositoryStartupFailure {
                #expect(failure.startupFailure.report.diagnostics.map(\.diagnostic.issue) == [
                    .baseline(.requiredBaselineUnavailable(.incompatibleSetup)),
                ])
                guard case let .load(.loaded(definition, skipped)) = failure.evidence else {
                    Issue.record("Expected exact skipped header evidence"); return
                }
                #expect(definition.attachments.isEmpty)
                #expect(skipped.count == 1)
            }
            #expect(probe.preparationCount == 0)
            #expect(probe.activationCount == 0)
        } else {
            let result = try await setup.execute { lease in
                if mode == .record {
                    try lease.append(capturing: { 9 }, preparation: ValuePreparation<UInt64>())
                }
            }
            let issues: [DiagnosticIssue] = mode == .record ?
                [.baseline(.baselineIgnoredForRecording(.incompatibleSetup))] : []
            #expect(result.finalization.report.diagnostics.map(\.diagnostic.issue) == issues)
            #expect(result.finalization.report.recordingHealth.isHealthy)
        }
        #expect(storage.readCount == 1)
        #expect(storage.writeCount == (mode == .record ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func `registered inactive instances must decode supported valid payloads`(unsupported: Bool) async throws {
        let bytes = document([
            entry("active"),
            entry("inactive", version: unsupported ? 2 : 1, payload: unsupported ? "{\"values\":[]}" : "null"),
        ])
        let probe = StartupProbe()
        let system = try probe.system(key: "active")
        let setup = try Diorama(
            repository: randomRepository(storage: StartupStorage(document: bytes)),
            scenarioID: "unknown-types", mode: .replay, systems: system)
        await #expect(throws: ScenarioRepositoryStartupFailure.self) { try await setup.execute { _ in () } }
        #expect(probe.preparationCount == 0)
        #expect(probe.activationCount == 0)
    }

    @Test
    func `known and unknown inactive instances are diagnosed without activating them`() async throws {
        let bytes = document([
            entry("known-unused"), entry("active"), entry("unknown-unused", type: "future.system"),
        ])
        let probe = StartupProbe()
        let setup = try Diorama(
            repository: randomRepository(storage: StartupStorage(document: bytes)),
            scenarioID: "unknown-types", mode: .replay, systems: probe.system(key: "active"))
        let result = try await setup.execute { lease in try lease.claimNext().value }
        #expect(result.body == 7)
        #expect(result.finalization.usage.count == 1)
        #expect(result.finalization.report.diagnostics.map(\.diagnostic.issue) == [
            .baseline(.loadedAttachmentNotConfigured), .baseline(.loadedAttachmentNotConfigured),
        ])
        #expect(probe.activationCount == 1)
    }

    @Test(arguments: [
        "duplicate-unknown", "duplicate-known", "duplicate-different", "missing-payload",
        "bad-version", "bad-type", "bad-key", "extra-header", "malformed-json", "envelope",
    ])
    func `omission never bypasses document and header validation`(kind: String) async throws {
        let unknown = entry("inactive", type: "future.system")
        let invalid: String = switch kind {
        case "duplicate-unknown": unknown + "," + unknown
        case "duplicate-known": entry("active", type: "future.system")
        case "duplicate-different": unknown + "," + entry("inactive", type: "other.system")
        case "missing-payload": "{\"attachmentKey\":\"inactive\",\"type\":\"future.system\",\"schemaVersion\":1}"
        case "bad-version": unknown.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":-1")
        case "bad-type": unknown.replacingOccurrences(of: "\"future.system\"", with: "null")
        case "bad-key": unknown.replacingOccurrences(of: "\"inactive\"", with: "42")
        case "extra-header": "{\"unexpected\":true," + unknown.dropFirst()
        case "malformed-json": entry("inactive", type: "future.system", payload: "{\"broken\":}")
        default: unknown
        }
        let bytes = document([entry("active"), invalid], envelope: kind == "envelope" ? 2 : 1)
        let probe = StartupProbe()
        let setup = try Diorama(
            repository: randomRepository(storage: StartupStorage(document: bytes)),
            scenarioID: "unknown-types", mode: .replay, systems: probe.system(key: "active"))
        await #expect(throws: ScenarioRepositoryStartupFailure.self) { try await setup.execute { _ in () } }
        #expect(probe.preparationCount == 0)
        #expect(probe.activationCount == 0)
    }

    @Test
    func `unknown omissions do not supply missing replay content`() async throws {
        let probe = StartupProbe()
        let setup = try Diorama(
            repository: randomRepository(storage: StartupStorage(document: document([
                entry("inactive", type: "future.system"),
            ]))), scenarioID: "unknown-types", mode: .replay, systems: probe.system(key: "active"))
        do {
            _ = try await setup.execute { _ in () }
            Issue.record("Missing replay content started")
        } catch let failure as ScenarioRepositoryStartupFailure {
            #expect(failure.startupFailure.report.diagnostics.map(\.diagnostic.issue) == [
                .baseline(.replayAttachmentMissing),
            ])
        }
        #expect(probe.activationCount == 0)
    }

    private func entry(
        _ key: String, type: String = DioramaRandomSystem.type.id.rawValue, version: UInt32 = 1,
        payload: String = "{\"values\":[7]}") -> String
    {
        "{\"attachmentKey\":\"\(key)\",\"type\":\"\(type)\",\"schemaVersion\":\(version),\"payload\":\(payload)}"
    }

    private func document(_ entries: [String], envelope: Int = 1) -> Data {
        Data("{\"diorama\":{\"schemaVersion\":\(envelope)},\"systems\":[\(entries.joined(separator: ","))]}".utf8)
    }
}
