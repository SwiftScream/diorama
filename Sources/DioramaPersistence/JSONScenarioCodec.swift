import DioramaCore
import Foundation

/// Deterministic UTF-8 JSON transport for persisted scenario documents.
///
/// The versioned `Codable` object model is format-neutral. This wrapper only
/// selects JSON, configures its canonical formatting, and collects resource bytes.
public struct JSONScenarioCodec: Sendable {
    /// The only envelope schema version currently written and read.
    public static let schemaVersion: UInt32 = 1

    private let registry: PersistentSystemRegistry

    /// Creates a JSON transport using capabilities collected from system types.
    ///
    /// - Parameter registry: Writers and readers from the known system types.
    public init(registry: PersistentSystemRegistry) {
        self.registry = registry
    }

    func validatePersistability(of definition: ScenarioDefinition)
        throws(PersistenceDispatchError)
    {
        try registry.validatePersistability(of: definition)
    }

    /// Encodes one complete document with canonical version-one JSON and resource bytes.
    ///
    /// JSON is pretty-printed UTF-8 with sorted object keys, semantic array
    /// order, unescaped slashes, and exactly one trailing newline.
    /// Missing resource bytes and conflicting references fail before a document is returned.
    ///
    /// - Parameter scenario: Prepared scenario content to encode.
    /// - Returns: Canonical JSON and the exact prepared resources it references.
    public func encode(_ scenario: ScenarioDefinition) throws -> ScenarioDocument {
        let resources = ResourceCollector()
        let encoder = JSONEncoder()
        encoder.userInfo[resourceCodingKey] = resources
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.userInfo[persistentSystemRegistryUserInfoKey] = registry
        var data = try encoder.encode(PersistedScenarioEnvelope(scenario))
        if data.last != Self.newline {
            data.append(Self.newline)
        }
        return try resources.document(data)
    }

    /// Decodes and validates one versioned JSON document.
    ///
    /// Every system type must be registered; unknown types are errors. Execution
    /// startup uses the same decoder with an internal discard policy instead.
    /// - Parameter data: UTF-8 JSON document bytes.
    /// - Returns: Prepared scenario content in persisted semantic order.
    public func decode(_ data: Data) throws -> ScenarioDefinition {
        try decode(data, unknownSystems: .reject).scenario
    }

    func decode(_ data: Data, unknownSystems: UnknownSystemPolicy,
                snapshot: ScenarioDocumentSnapshot? = nil) throws -> PersistedScenarioEnvelope
    {
        let decoder = JSONDecoder()
        decoder.userInfo[resourceCodingKey] = snapshot
        decoder.userInfo[persistentSystemRegistryUserInfoKey] = registry
        decoder.userInfo[unknownSystemPolicyUserInfoKey] = unknownSystems
        do {
            return try decoder.decode(PersistedScenarioEnvelope.self, from: data)
        } catch let error as PersistedScenarioCodingError {
            throw error
        } catch let error as DecodingError {
            throw persistedScenarioCodingError(for: error)
        }
    }

    private static let newline = UInt8(ascii: "\n")
}
