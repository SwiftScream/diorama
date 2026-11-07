import HTTPTypes

/// A valid HTTP field value whose original bytes are preserved exactly.
public struct HTTPFieldValue: Hashable, Sendable {
    /// Exact field bytes, including non-UTF-8 bytes.
    public let bytes: [UInt8]

    /// UTF-8 text when the complete value has a lossless UTF-8 representation.
    public var text: String? {
        String(validating: bytes, as: UTF8.self)
    }

    /// Creates a value without silently repairing disallowed HTTP bytes.
    public init(bytes: [UInt8]) throws {
        guard HTTPField.isValidValue(bytes) else { throw HTTPMessageError.invalidField }
        self.bytes = bytes
    }

    /// Creates a field value from its UTF-8 text.
    public init(_ text: String) throws {
        try self.init(bytes: Array(text.utf8))
    }
}

/// A rule's decision for one captured field occurrence.
public enum HTTPFieldRedactionResult: Equatable, Sendable {
    /// Retain the original field exactly; it satisfies this rule's safety policy.
    case safe
    /// Replace the value without emitting a warning.
    case replace(HTTPFieldValue)
    /// Replace the value and emit the policy's safe replacement-warning diagnostic.
    case replaceWithWarning(HTTPFieldValue)
    /// Omit this occurrence while preserving the order of remaining fields.
    case remove
}

/// An immutable field rule with separate capture and prepared-admission operations.
///
/// Closures must be deterministic, idempotent, and must not log their inputs.
/// The policy owns warnings; thrown errors become safe preparation failures.
public struct HTTPFieldRedactionRule: Sendable {
    let redact: @Sendable (HTTPFieldValue) throws -> HTTPFieldRedactionResult
    let validate: @Sendable (HTTPFieldValue) throws -> Void

    /// Creates a rule. Validation must reject retained values that violate its policy.
    ///
    /// Validation runs after capture transforms and on decoded or edited values;
    /// it must not mutate them. It is not called for an absent field.
    public init(
        redact: @escaping @Sendable (HTTPFieldValue) throws -> HTTPFieldRedactionResult,
        validate: @escaping @Sendable (HTTPFieldValue) throws -> Void)
    {
        self.redact = redact
        self.validate = validate
    }

    /// Replaces every occurrence and accepts only the exact replacement bytes.
    public static func constant(_ value: HTTPFieldValue) -> Self {
        Self(redact: { $0 == value ? .safe : .replace(value) }, validate: {
            guard $0 == value else { throw HTTPMessageError.invalidField }
        })
    }

    /// Creates a constant replacement from validated UTF-8 text.
    public static func constant(_ text: String) throws -> Self {
        try constant(HTTPFieldValue(text))
    }

    /// Removes every captured occurrence and rejects any retained prepared occurrence.
    public static let remove = Self(redact: { _ in .remove }, validate: { _ in
        throw HTTPMessageError.invalidField
    })
}
