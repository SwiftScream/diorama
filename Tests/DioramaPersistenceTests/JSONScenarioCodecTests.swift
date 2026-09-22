import DioramaCore
import DioramaPersistence
@testable import DioramaRandom
import Foundation
import Testing

struct JSONScenarioCodecTests {
    @Test
    func `writer matches independent empty and boundary goldens`() throws {
        let empty = try document(key: "empty", values: [])
        let boundaries = try document(key: "boundaries", values: [0, .max])

        #expect(try codec().encode(empty) == fixture("random-empty"))
        #expect(try codec().encode(boundaries) == fixture("random-boundaries"))
    }

    @Test
    func `reader preserves independent fixture order and full UInt64 precision`() throws {
        let decoded = try codec().decode(fixture("random-boundaries"))

        #expect(decoded.attachments.map(\.id.key.rawValue) == ["boundaries"])
        #expect(try randomValues(in: decoded.attachments[0]) == [0, UInt64.max])
        #expect(try codec().encode(decoded) == fixture("random-boundaries"))
    }

    @Test
    func `reads the human-readable random scenario example`() throws {
        let decoded = try codec().decode(fixture("random-example"))

        #expect(decoded.attachments.map(\.id.key.rawValue) == ["account-id", "retry-jitter"])
        #expect(try decoded.attachments.map(randomValues(in:)) == [
            [1842, 90731, 412],
            [17, 63],
        ])
    }

    @Test
    func `empty scenario and repeated random instances preserve semantic array order`() throws {
        let codec = try codec()
        let empty = try ScenarioDefinition()
        let ordered = try ScenarioDefinition(attachments: [
            randomAttachment(key: "second", values: [2]),
            randomAttachment(key: "first", values: [1]),
        ])

        #expect(try codec.decode(codec.encode(empty)).attachments.isEmpty)
        let decoded = try codec.decode(codec.encode(ordered))
        #expect(decoded.attachments.map(\.id.key.rawValue) == ["second", "first"])
        #expect(try decoded.attachments.map(randomValues(in:)) == [[2], [1]])
    }

    @Test
    func `canonical bytes are pretty sorted UTF8 with one trailing newline`() throws {
        let data = try codec().encode(document(key: "path/segment", values: [7]))
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text.contains("\"attachmentKey\" : \"path/segment\""))
        #expect(!text.contains("path\\/segment"))
        #expect(text.hasSuffix("}\n"))
        #expect(!text.hasSuffix("}\n\n"))
        #expect(!text.contains("timestamp"))
        #expect(!text.contains("packageVersion"))
    }

    @Test
    func `unversioned POC input is rejected without schema inference`() throws {
        #expect(throws: PersistedScenarioCodingError.unversionedEnvelope) {
            _ = try codec().decode(fixture("unversioned-poc"))
        }
    }

    @Test(
        arguments: [
            ("unknown-envelope-field", PersistedScenarioCodingError.unknownField(codingPath: [], field: "metadata")),
            (
                "unknown-header-field",
                PersistedScenarioCodingError.unknownField(codingPath: ["diorama"], field: "writer")),
            (
                "unknown-system-field",
                PersistedScenarioCodingError.unknownField(codingPath: ["systems", "0"], field: "mode")),
        ])
    func `strict Diorama structures reject unknown fields with safe paths`(
        fixtureName: String,
        expected: PersistedScenarioCodingError) throws
    {
        #expect(throws: expected) {
            _ = try codec().decode(fixture(fixtureName))
        }
    }

    @Test
    func `random payload rejects unknown nested fields with a safe path`() throws {
        #expect(throws: PersistedScenarioCodingError.unknownField(
            codingPath: ["systems", "0", "payload"],
            field: "seed"))
        {
            _ = try codec().decode(fixture("unknown-random-field"))
        }
    }

    @Test
    func `malformed nested payload reports only its safe coding path`() throws {
        #expect(throws: PersistedScenarioCodingError.malformed(
            codingPath: ["systems", "0", "payload", "values"]))
        {
            _ = try codec().decode(fixture("malformed-random-values"))
        }
    }

    @Test(
        arguments: [
            (
                "missing-system-type",
                PersistedScenarioCodingError.malformed(codingPath: ["systems", "0", "type"])),
            (
                "null-random-values",
                PersistedScenarioCodingError.malformed(
                    codingPath: ["systems", "0", "payload", "values"])),
        ])
    func `missing and null values report only their safe schema paths`(
        fixtureName: String,
        expected: PersistedScenarioCodingError) throws
    {
        #expect(throws: expected) {
            _ = try codec().decode(fixture(fixtureName))
        }
    }

    @Test
    func `envelope and payload versions dispatch independently`() throws {
        let unsupportedRandomVersion: UInt32 = 2
        #expect(throws: PersistedScenarioCodingError.unsupportedEnvelopeVersion(
            declared: 2,
            supported: [1]))
        {
            _ = try codec().decode(fixture("unsupported-envelope-version"))
        }
        #expect(throws: PersistenceDispatchError.unsupportedSchemaVersion(
            systemTypeID: DioramaRandomSystem.type.id,
            declared: unsupportedRandomVersion,
            supported: [DioramaRandomPersistence.schemaVersion]))
        {
            _ = try codec().decode(fixture("unsupported-random-version"))
        }
    }

    @Test
    func `zero versions are valid but unsupported`() throws {
        #expect(throws: PersistedScenarioCodingError.unsupportedEnvelopeVersion(
            declared: 0,
            supported: [JSONScenarioCodec.schemaVersion]))
        {
            _ = try codec().decode(fixture("zero-envelope-version"))
        }
        #expect(throws: PersistenceDispatchError.unsupportedSchemaVersion(
            systemTypeID: DioramaRandomSystem.type.id,
            declared: 0,
            supported: [DioramaRandomPersistence.schemaVersion]))
        {
            _ = try codec().decode(fixture("zero-random-version"))
        }
    }

    @Test
    func `versions outside the non-negative UInt32 range are malformed`() throws {
        let expected = PersistedScenarioCodingError.malformed(
            codingPath: ["systems", "0", "schemaVersion"])
        #expect(throws: expected) {
            _ = try codec().decode(fixture("negative-system-version"))
        }
        #expect(throws: expected) {
            _ = try codec().decode(fixture("out-of-range-system-version"))
        }
        #expect(throws: expected) {
            _ = try codec().decode(fixture("nonnumeric-system-version"))
        }
    }

    @Test
    func `duplicate attachment keys are rejected`() throws {
        let first = try randomAttachment(key: "duplicate", values: [1])
        let second = try randomAttachment(key: "duplicate", values: [2])
        #expect(throws: ScenarioDefinitionError.duplicateAttachment(first.id)) {
            _ = try ScenarioDefinition(attachments: [first, second])
        }
    }

    @Test
    func `attachment keys cannot identify different persisted system types`() throws {
        let key = "shared"
        let numbers = try PersistentSystemRegistryTests.numberAttachment(key: key, values: [1])
        let labels = try PersistentSystemRegistryTests.labelAttachment(key: key, values: ["one"])

        #expect(throws: ScenarioDefinitionError.incompatibleAttachmentSystem(
            key: AttachmentKey(rawValue: key),
            existing: PersistentSystemRegistryTests.numberType,
            proposed: PersistentSystemRegistryTests.labelType))
        {
            _ = try ScenarioDefinition(attachments: [numbers, labels])
        }
    }

    @Test
    func `random writer rejects any noncanonical track layout`() throws {
        let invalid = ScenarioAttachment(
            id: DioramaRandomSystem.attachmentID(
                for: AttachmentKey(rawValue: "invalid-layout")))
        let document = try ScenarioDefinition(attachments: [invalid])

        #expect(throws: PersistentSystemEncodingError.invalidTrackLayout(invalid.id)) {
            _ = try codec().encode(document)
        }
    }

    private func codec() throws -> JSONScenarioCodec {
        try JSONScenarioCodec(
            registry: PersistentSystemRegistry([
                DioramaRandomSystem.type,
            ]))
    }

    private func document(key: String, values: [UInt64]) throws -> ScenarioDefinition {
        try ScenarioDefinition(attachments: [randomAttachment(key: key, values: values)])
    }

    private func randomAttachment(key: String, values: [UInt64]) throws -> ScenarioAttachment {
        let key = AttachmentKey(rawValue: key)
        let trackID = DioramaRandomSystem.trackID(for: key)
        return try ScenarioAttachment(id: DioramaRandomSystem.attachmentID(for: key)).adding(
            SequentialTrack(
                id: trackID,
                values: prepared(values, trackID: trackID)))
    }

    private func prepared(
        _ values: [UInt64],
        trackID: TrackID) throws -> [PreparedValue<UInt64>]
    {
        let definition = try ScenarioDefinition()
        let reporter = DiagnosticReporter(scenarioID: ScenarioID(rawValue: "json-codec-tests"), definition: definition)
        let preparation = ValuePreparation<UInt64>()
        return try values.enumerated().map { index, value in
            try preparation.prepare(
                capturing: { value },
                purpose: .replay,
                reporter: reporter,
                context: .record(
                    RecordIdentity(
                        trackID: trackID,
                        sequence: UInt64(index))))
        }
    }

    private func randomValues(in attachment: ScenarioAttachment) throws -> [UInt64] {
        let trackID = DioramaRandomSystem.trackID(for: attachment.id.key)
        let track = try attachment.track(trackID, as: UInt64.self)
        return try #require(track).records.map(\.value)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}
