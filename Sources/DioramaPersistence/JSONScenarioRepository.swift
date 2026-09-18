import DioramaCore
import Foundation

/// A complete load outcome retained before execution policy is applied.
///
/// Associated errors preserve codec and backend evidence for inspection. Custom
/// errors must be made safe before rendering; this type never renders them.
public enum ScenarioLoadResult: Sendable {
    /// Fully decoded and prepared content, including a valid empty scenario.
    case loaded(PersistedScenario)

    /// Storage contains no document at the configured destination.
    case missing

    /// Storage could not supply document bytes.
    case unreadable(any Error)

    /// The document or a registered payload failed decoding or validation.
    case invalidDocument(any Error)

    /// The envelope is unversioned or declares an unsupported schema version.
    case incompatibleEnvelope(PersistedScenarioCodingError)

    /// A system is unknown, incompatible, or declares an unsupported version.
    case incompatibleSystem(PersistenceDispatchError)
}

/// A failed publication before storage commits the new document.
public enum ScenarioPublicationError: Error, Sendable {
    /// Encoding failed before any storage publication was attempted.
    case encoding(any Error)

    /// Storage failed before commit, potentially with additional cleanup evidence.
    case storage(any Error)
}

/// Composes the deterministic JSON codec with storage for one scenario.
///
/// Each load reads once and retains its precise outcome. Each publication encodes
/// the complete supplied candidate before asking storage to write. Execution
/// startup, candidate health, and finalization policy belong to the caller.
/// Operations are synchronous and may block the caller.
public struct JSONScenarioRepository: Sendable {
    private let codec: JSONScenarioCodec
    private let storage: any ScenarioDocumentStorage

    /// Creates a repository from independent semantic and storage boundaries.
    ///
    /// - Parameters:
    ///   - codec: Registered readers and writers for the complete scenario.
    ///   - storage: Storage already bound to the consumer's scenario destination.
    public init(codec: JSONScenarioCodec, storage: any ScenarioDocumentStorage) {
        self.codec = codec
        self.storage = storage
    }

    /// Loads and prepares one document without applying runtime mode policy.
    ///
    /// - Returns: The exact load outcome; invalid content is never treated as empty.
    public func load() -> ScenarioLoadResult {
        let data: Data
        do {
            guard let loaded = try storage.load() else { return .missing }
            data = loaded
        } catch {
            return .unreadable(error)
        }
        do {
            return try .loaded(codec.decode(data))
        } catch let error as PersistenceDispatchError {
            return .incompatibleSystem(error)
        } catch let error as PersistedScenarioCodingError {
            switch error {
            case .unversionedEnvelope, .unsupportedEnvelopeVersion:
                return .incompatibleEnvelope(error)
            case .unknownField, .malformed:
                return .invalidDocument(error)
            }
        } catch {
            return .invalidDocument(error)
        }
    }

    /// Verifies that runtime setup can be represented by this repository.
    ///
    /// Validation happens without reading or writing storage. Every active
    /// attachment, including an ignored one, requires registration. Loading
    /// separately validates every payload before discarding unmatched content.
    ///
    /// - Parameter definition: The runtime setup to validate.
    /// - Throws: The first missing persistent-system registration.
    public func validatePersistability(of definition: ScenarioDefinition)
        throws(PersistenceDispatchError)
    {
        try codec.validatePersistability(of: definition)
    }

    /// Encodes and publishes a complete candidate as one document.
    ///
    /// - Parameter candidate: Complete prepared content selected by the caller.
    /// - Returns: A commit receipt, retaining any subsequent cleanup failure.
    /// - Throws: A distinct encoding or precommit storage failure.
    public func publish(_ candidate: PersistedScenario)
        throws(ScenarioPublicationError) -> DocumentPublication
    {
        let data: Data
        do {
            data = try codec.encode(candidate)
        } catch {
            throw .encoding(error)
        }
        do {
            return try storage.publish(data)
        } catch {
            throw .storage(error)
        }
    }
}
