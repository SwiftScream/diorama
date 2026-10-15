import DioramaPersistence
import Foundation
import Testing

struct EnvelopeVersionClassificationTests {
    @Test(arguments: [
        #"{"systems":[]}"#,
        #"{"diorama":{},"systems":[]}"#,
    ])
    func `absent envelope versions remain incompatible through codec and repository`(json: String) throws {
        try check(json, error: .unversionedEnvelope, incompatible: true)
    }

    @Test(arguments: ["null", #""1""#, "-1", "4294967296"])
    func `malformed envelope versions remain invalid documents`(version: String) throws {
        try check(#"{"diorama":{"schemaVersion":\#(version)},"systems":[]}"#,
                  error: .malformed(codingPath: ["diorama", "schemaVersion"]), incompatible: false)
    }

    @Test
    func `fractional envelope versions remain invalid documents`() throws {
        let data = Data(#"{"diorama":{"schemaVersion":1.5},"systems":[]}"#.utf8)
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry())
        #expect(throws: PersistedScenarioCodingError.self) { _ = try codec.decode(data) }
        let repository = JSONScenarioRepository(codec: codec, storage: ReadOnlyDocument(data: data))
        guard case let .invalidDocument(error) = repository.load(),
              case .malformed = error as? PersistedScenarioCodingError
        else {
            Issue.record("Fractional versions must remain malformed documents"); return
        }
    }

    @Test(arguments: [UInt32(0), 2, .max])
    func `unsupported envelope versions preserve their declared value`(version: UInt32) throws {
        try check(#"{"diorama":{"schemaVersion":\#(version)},"systems":[]}"#,
                  error: .unsupportedEnvelopeVersion(declared: version, supported: [1]), incompatible: true)
    }

    @Test
    func `missing system version remains a malformed system entry`() throws {
        try check(#"""
        {"diorama":{"schemaVersion":1},"systems":[
          {"attachmentKey":"random","type":"diorama.random","payload":{"values":[]}}
        ]}
        """#, error: .malformed(codingPath: ["systems", "0", "schemaVersion"]), incompatible: false)
    }

    private func check(_ json: String, error: PersistedScenarioCodingError, incompatible: Bool) throws {
        let data = Data(json.utf8)
        let codec = try JSONScenarioCodec(registry: PersistentSystemRegistry())
        #expect(throws: error) { _ = try codec.decode(data) }
        let repository = JSONScenarioRepository(codec: codec, storage: ReadOnlyDocument(data: data))
        switch repository.load() {
        case let .incompatibleEnvelope(actual):
            #expect(incompatible)
            #expect(actual == error)
        case let .invalidDocument(actual):
            #expect(!incompatible)
            #expect(actual as? PersistedScenarioCodingError == error)
        default:
            Issue.record("Expected a rejected document with its exact version classification")
        }
    }
}

private struct ReadOnlyDocument: ScenarioDocumentStorage {
    let data: Data

    func load() -> Data? {
        data
    }

    func publish(_: Data) -> DocumentPublication {
        Issue.record("Version classification must not publish a document")
        return DocumentPublication()
    }
}
