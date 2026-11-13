import DioramaCore
import DioramaPersistence
import Foundation
import HTTPTypes

/// Immutable recording-only placement of prepared HTTP body bytes.
///
/// Exact media-type overrides precede enabled standard rules, then the fallback rule.
/// Decoding, admission, matching, and replay never invoke this policy. Adapters
/// select it during setup and call it only for newly recorded prepared content.
public struct HTTPBodyStoragePolicy: Sendable {
    /// One placement rule, optionally overriding the resource suffix.
    public struct Rule: Sendable {
        fileprivate enum Placement: Sendable {
            case inline
            case resource
            case threshold(UInt)
        }

        fileprivate let placement: Placement
        fileprivate let fileExtension: String?

        /// Retains every byte inline; the codec chooses lossless UTF-8 or base64.
        public static let inline = Self(placement: .inline, fileExtension: nil)

        /// Inlines up to and including 200 prepared bytes, with an optional resource suffix.
        public static func standard(fileExtension: String? = nil) -> Self {
            Self(placement: .threshold(200), fileExtension: sanitizedExtension(fileExtension))
        }

        /// Always creates a resource, including for present empty content.
        ///
        /// `/` and `\` scalars are stripped from an explicit suffix; other spelling is preserved.
        /// It is appended after a dot; an empty suffix produces a trailing dot.
        /// Nil uses the media-type standard extension, or `bin` when none is available.
        /// The resulting resource path is validated.
        public static func resource(fileExtension: String? = nil) -> Self {
            Self(placement: .resource, fileExtension: sanitizedExtension(fileExtension))
        }

        /// Creates resources only above the inclusive prepared-byte limit.
        ///
        /// The limit measures bytes before JSON escaping or base64 encoding.
        /// Zero retains empty content inline and creates resources for nonempty content.
        /// Explicit extensions follow the same contract as `resource`.
        public static func automatic(inlineByteLimit: UInt, fileExtension: String? = nil) -> Self {
            Self(placement: .threshold(inlineByteLimit), fileExtension: sanitizedExtension(fileExtension))
        }

        private static func sanitizedExtension(_ value: String?) -> String? {
            guard let value else { return nil }
            let scalars = value.unicodeScalars.filter { $0 != "/" && $0 != "\\" }
            return String(String.UnicodeScalarView(scalars))
        }
    }

    private let rules: [String: Rule]
    private let fallback: Rule
    private let useStandardRules: Bool

    /// Creates literal-key overrides, optional standard rules, and a fallback.
    ///
    /// Keys are stored exactly as supplied and compared against the normalized header hint.
    /// No key validation, normalization, or wildcard interpretation occurs.
    /// Disabling standard rules leaves media-type standard extensions available.
    public init(rules: [String: Rule] = [:], fallback: Rule = .standard(), useStandardRules: Bool = true) {
        self.rules = rules
        self.fallback = fallback
        self.useStandardRules = useStandardRules
    }

    /// Recognized images use resources; other types use the inclusive 200-byte limit.
    public static let `default` = Self()

    /// Inlines every newly recorded byte body; existing baseline resources remain unchanged.
    public static let allInline = Self(fallback: .inline, useStandardRules: false)

    /// Selects storage for newly recorded prepared request bytes without changing the head.
    ///
    /// Absent content and existing resource references remain exact. `resourceStem`
    /// is a caller-assigned portable relative path, normally based on record identity.
    /// A selected suffix is appended literally. H07 rejects publication collisions.
    /// The stem is validated only when creating a resource; no I/O occurs here.
    public func request(_ prepared: PreparedValue<HTTPRequestMessage>, resourceStem: String) throws
        -> HTTPRequestMessage
    {
        let request = prepared.value
        guard case let .bytes(bytes) = request.body else { return request }
        let body: HTTPRequestBody = switch try select(bytes, fields: request.head.headerFields, stem: resourceStem) {
        case let .resource(resource): .resource(resource)
        default: .bytes(bytes)
        }
        return try HTTPRequestMessage(head: request.head, body: body)
    }

    /// Selects storage for newly recorded prepared response content or an observed prefix.
    ///
    /// Absent, unavailable, and existing resource cases are preserved. Headers are
    /// prepared hints for rule lookup. Extensions come from rules without inspecting
    /// body bytes or Content-Encoding. No decompression, transcoding, parsing, or
    /// body normalization occurs.
    public func response(_ prepared: PreparedValue<HTTPResponseBody>, head: PreparedValue<HTTPResponseHead>,
                         resourceStem: String) throws -> HTTPResponseBody
    {
        guard case let .bytes(bytes) = prepared.value else { return prepared.value }
        return try select(bytes, fields: head.value.head.headerFields, stem: resourceStem)
    }

    private func select(_ bytes: [UInt8], fields: HTTPFields, stem: String) throws -> HTTPResponseBody {
        let mediaType = BodyStorageMediaType.hint(in: fields)
        let rule = rule(for: mediaType)
        switch rule.placement {
        case .inline: return .bytes(bytes)
        case let .threshold(limit) where UInt(bytes.count) <= limit: return .bytes(bytes)
        case .resource, .threshold: break
        }
        let suffix = rule.fileExtension ?? mediaType.flatMap { Self.standardRule(for: $0)?.fileExtension } ?? "bin"
        // Validate the stem independently so adding a suffix cannot repair a bad path.
        do { _ = try ScenarioResourcePath(stem) } catch { throw HTTPMessageError.invalidResource }
        return try .resource(HTTPBodyResource(
            path: stem + "." + suffix,
            bytes: ValuePreparation<[UInt8]>().admitPrepared(bytes)))
    }

    private func rule(for mediaType: String?) -> Rule {
        guard let mediaType else { return fallback }
        if let override = rules[mediaType] {
            return override
        }
        if useStandardRules, let standard = Self.standardRule(for: mediaType) {
            return standard
        }
        return fallback
    }

    private static func standardRule(for mediaType: String) -> Rule? {
        if let rule = standardRules[mediaType] {
            return rule
        }
        if mediaType.hasPrefix("application/"), mediaType.hasSuffix("+json") {
            return .standard(fileExtension: "json")
        }
        if mediaType.hasPrefix("text/") {
            return .standard(fileExtension: "txt")
        }
        return nil
    }

    private static let standardRules: [String: Rule] = [
        "image/png": Rule(placement: .resource, fileExtension: "png"),
        "image/jpeg": Rule(placement: .resource, fileExtension: "jpeg"),
        "image/gif": Rule(placement: .resource, fileExtension: "gif"),
        "image/webp": Rule(placement: .resource, fileExtension: "webp"),
        "application/json": .standard(fileExtension: "json"),
        "text/html": .standard(fileExtension: "html"),
        "text/css": .standard(fileExtension: "css"),
        "text/csv": .standard(fileExtension: "csv"),
        "text/javascript": .standard(fileExtension: "js"),
        "application/javascript": .standard(fileExtension: "js"),
        "application/xml": .standard(fileExtension: "xml"),
        "text/xml": .standard(fileExtension: "xml"),
    ]
}

private enum BodyStorageMediaType {
    static func hint(in fields: HTTPFields) -> String? {
        let types = fields.filter { $0.name == .contentType }
        guard types.count == 1 else { return nil }
        let value = fieldText(types[0])
        return String(value.unicodeScalars.prefix { $0 != ";" })
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t")).lowercased()
    }

    private static func fieldText(_ field: HTTPField) -> String {
        field.withUnsafeBytesOfValue { bytes in
            String(String.UnicodeScalarView(bytes.map { UnicodeScalar($0) }))
        }
    }
}
