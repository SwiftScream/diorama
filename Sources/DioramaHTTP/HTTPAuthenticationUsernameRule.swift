/// A setup-owned rule for nonempty authentication usernames.
///
/// The same rule prepares proposed and selected credentials. Absent and empty
/// usernames bypass the rule and remain distinct. Custom rules replace the
/// default, must be deterministic and idempotent, and must not log their inputs.
public struct HTTPAuthenticationUsernameRule: Sendable {
    private let transform: @Sendable (String) throws -> String
    private let validatePrepared: @Sendable (String) throws -> Void

    /// Creates a custom mapping with separate prepared-value validation.
    ///
    /// Both closures receive only nonempty usernames. Redaction must return a
    /// nonempty safe substitute; validation must reject disallowed prepared values.
    public init(redact: @escaping @Sendable (String) throws -> String,
                validate: @escaping @Sendable (String) throws -> Void)
    {
        transform = redact
        validatePrepared = validate
    }

    /// Replaces nonempty usernames with `redacted`.
    public static let `default` = Self(replacement: "redacted")

    /// Replaces nonempty usernames with one nonempty setup-selected value.
    ///
    /// Prepared admission accepts only that exact replacement for nonempty usernames.
    public static func constant(_ replacement: String) throws -> Self {
        guard !replacement.isEmpty else { throw HTTPAuthenticationPreparationError.emptyUsernameReplacement }
        return Self(replacement: replacement)
    }

    private init(replacement: String) {
        self.init(redact: { _ in replacement }, validate: {
            guard $0 == replacement else { throw HTTPAuthenticationPreparationError.invalidPreparedUsername }
        })
    }

    func redact(_ user: String?) throws -> String? {
        guard let user, !user.isEmpty else { return user }
        let replacement = try transform(user)
        guard !replacement.isEmpty else { throw HTTPAuthenticationPreparationError.invalidPreparedUsername }
        return replacement
    }

    func validate(_ user: String?) throws {
        guard let user, !user.isEmpty else { return }
        try validatePrepared(user)
    }
}

/// Safe authentication preparation errors without identity contents.
public enum HTTPAuthenticationPreparationError: Error, Equatable, Sendable {
    /// A constant replacement must preserve the nonempty username case.
    case emptyUsernameReplacement
    /// A transformed or authored username does not satisfy the selected rule.
    case invalidPreparedUsername
}
