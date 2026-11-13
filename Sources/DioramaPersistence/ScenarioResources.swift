import DioramaCore
import Foundation
import Synchronization

/// Safe resource failure categories; paths and bytes are never rendered.
public enum ScenarioResourceError: Error, Equatable, Sendable {
    /// A path is not a contained relative resource name.
    case invalidPath
    /// Two resources disagree or their names alias on a supported filesystem.
    case conflictingResource
    /// The referenced bytes could not be read.
    case unavailable
    /// This storage cannot publish resources atomically.
    case unsupportedStorage
}

/// A literal relative path beneath one scenario's resource directory.
public struct ScenarioResourcePath: Hashable, Sendable {
    /// Slash-separated, case-preserving components, including spaces and Unicode.
    public let value: String

    /// Rejects empty, dot, dot-dot, and NUL-containing components without filesystem access.
    /// Names are literal; percent escapes are not decoded. Filesystem-specific limits apply at I/O.
    public init(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".." && !part.contains("\u{0}")
        }) else { throw ScenarioResourceError.invalidPath }
        self.value = value
    }
}

/// An encoded document and the exact prepared resources it references.
public struct ScenarioDocument: Sendable {
    /// Canonical encoded scenario bytes.
    public let data: Data
    /// Prepared resources, keyed by relative path.
    public let resources: [ScenarioResourcePath: Data]

    /// Creates a publication after rejecting case aliases and file/directory conflicts.
    public init(data: Data, resources: [ScenarioResourcePath: Data] = [:]) throws {
        let names = Set(resources.keys.map { $0.value.lowercased() })
        guard names.count == resources.count else { throw ScenarioResourceError.conflictingResource }
        var spellings: [String: String] = [:]
        for path in resources.keys.sorted(by: { $0.value < $1.value }) {
            let parts = path.value.split(separator: "/")
            var prefix = ""
            for (index, part) in parts.enumerated() {
                prefix += (prefix.isEmpty ? "" : "/") + part
                let folded = prefix.lowercased()
                if let previous = spellings[folded], previous != prefix {
                    throw ScenarioResourceError.conflictingResource
                }
                if index < parts.count - 1, names.contains(folded) {
                    throw ScenarioResourceError.conflictingResource
                }
                spellings[folded] = prefix
            }
        }
        self.data = data
        self.resources = resources
    }
}

/// One document and resource-reading view, valid within the caller-controlled loading window.
public struct ScenarioDocumentSnapshot: Sendable {
    /// Complete document bytes.
    public let data: Data
    private let read: @Sendable (ScenarioResourcePath) throws -> Data

    /// Creates a read-only snapshot. Resolve resources before publishing the same scenario.
    /// Backends may provide a longer lifetime; loaded semantic values must own their bytes.
    public init(data: Data, resource: @escaping @Sendable (ScenarioResourcePath) throws -> Data = { _ in
        throw ScenarioResourceError.unavailable
    }) {
        self.data = data
        read = resource
    }

    /// Resolves exact bytes, reducing backend errors to a safe infrastructure category.
    public func resource(at path: ScenarioResourcePath) throws -> Data {
        do { return try read(path) } catch { throw ScenarioResourceError.unavailable }
    }
}

/// Resource context shared by the codecs of one complete document.
/// Systems call these helpers from their deliberate Codable implementations.
public enum ScenarioResourceCoding {
    /// Registers already-prepared bytes in the scenario encoder's resource context.
    /// `JSONScenarioCodec.encode` always supplies this context.
    public static func encode(_ bytes: PreparedValue<[UInt8]>, at path: ScenarioResourcePath,
                              to encoder: any Encoder) throws
    {
        try collector(encoder)?.insert(Data(bytes.value), at: path)
    }

    /// Rejects missing owned bytes when a scenario encoder is collecting resources.
    public static func requireBytes(to encoder: any Encoder) throws {
        if collector(encoder) != nil {
            throw ScenarioResourceError.unavailable
        }
    }

    /// Resolves a reference during repository decoding; standalone decoding returns nil.
    public static func decode(at path: ScenarioResourcePath, from decoder: any Decoder) throws -> Data? {
        try resolutionContext(from: decoder)?.resource(at: path)
    }

    /// Extracts the resource-resolution context for conversion outside a Codable initializer.
    /// Standalone decoders without a resource context return nil.
    public static func resolutionContext(from decoder: any Decoder) -> ScenarioDocumentSnapshot? {
        decoder.userInfo[resourceCodingKey] as? ScenarioDocumentSnapshot
    }

    private static func collector(_ encoder: any Encoder) -> ResourceCollector? {
        encoder.userInfo[resourceCodingKey] as? ResourceCollector
    }
}

let resourceCodingKey = CodingUserInfoKey(rawValue: "diorama.resources")!

final class ResourceCollector: Sendable {
    private let values = Mutex<[ScenarioResourcePath: Data]>([:])

    func insert(_ data: Data, at path: ScenarioResourcePath) throws {
        try values.withLock { values in
            if let existing = values[path], existing != data {
                throw ScenarioResourceError.conflictingResource
            }
            values[path] = data
        }
    }

    func document(_ data: Data) throws -> ScenarioDocument {
        try values.withLock { try ScenarioDocument(data: data, resources: $0) }
    }
}
