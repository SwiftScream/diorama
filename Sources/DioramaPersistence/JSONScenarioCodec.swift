import DioramaCore
import Foundation

/// Deterministic UTF-8 JSON transport for persisted scenario documents.
///
/// The versioned `Codable` object model is format-neutral. This wrapper only
/// selects JSON, configures its canonical formatting, and manages bytes.
public struct JSONScenarioCodec: Sendable {
    /// The only envelope schema version currently written and read.
    public static let schemaVersion: UInt32 = 1

    private let registry: PersistentSystemRegistry

    /// Creates a JSON transport using explicit persistent-system registrations.
    ///
    /// - Parameter registry: Writers and readers for every included system.
    public init(registry: PersistentSystemRegistry) {
        self.registry = registry
    }

    func validatePersistability(of definition: ScenarioDefinition)
        throws(PersistenceDispatchError)
    {
        try registry.validatePersistability(of: definition)
    }

    /// Encodes one complete semantic document as canonical version-one JSON.
    ///
    /// Output is pretty-printed UTF-8 with sorted object keys, semantic array
    /// order, unescaped slashes, and exactly one trailing newline.
    ///
    /// - Parameter scenario: Prepared scenario content to encode.
    /// - Returns: Canonical JSON bytes.
    public func encode(_ scenario: ScenarioDefinition) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.userInfo[persistentSystemRegistryUserInfoKey] = registry
        var data = try encoder.encode(PersistedScenarioEnvelope(scenario))
        if data.last != Self.newline {
            data.append(Self.newline)
        }
        return data
    }

    /// Decodes and validates one versioned JSON document.
    ///
    /// - Parameter data: UTF-8 JSON document bytes.
    /// - Returns: Prepared scenario content in persisted semantic order.
    public func decode(_ data: Data) throws -> ScenarioDefinition {
        let decoder = JSONDecoder()
        decoder.userInfo[persistentSystemRegistryUserInfoKey] = registry
        do {
            return try decoder.decode(PersistedScenarioEnvelope.self, from: data).scenario
        } catch let error as PersistedScenarioCodingError {
            throw error
        } catch let error as DecodingError {
            throw persistedScenarioCodingError(for: error)
        }
    }

    private static let newline = UInt8(ascii: "\n")
}
