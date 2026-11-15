import DioramaCore

public extension HTTPPreparation {
    /// Creates selected-credential preparation using the configured username rule.
    ///
    /// Custom redaction and normalization receive the substituted username. To map
    /// distinct captured identities, configure `authenticationUsername` instead.
    /// Final validation and prepared admission enforce that rule without reapplying it.
    func authenticationCredential(
        redact: @escaping @Sendable (HTTPAuthenticationCredential) throws -> HTTPAuthenticationCredential = { $0 },
        normalize: @escaping @Sendable (HTTPAuthenticationCredential) throws -> HTTPAuthenticationCredential = { $0 },
        validate: @escaping @Sendable (HTTPAuthenticationCredential) throws -> Void = { _ in })
        -> ValuePreparation<HTTPAuthenticationCredential>
    {
        ValuePreparation(redact: { value in
            try redact(redactCredential(value))
        }, normalize: normalize, validate: { value in
            try authenticationUsername.validate(value.user)
            try validate(value)
        })
    }

    /// Creates challenge preparation using the same rule for proposed usernames.
    ///
    /// Host, port, protocol, realm, and other metadata remain exact by default.
    /// Custom redaction can replace sensitive protection-space values; the same
    /// policy must account for related request URLs and challenge response fields.
    func authenticationChallenge(
        redact: @escaping @Sendable (HTTPAuthenticationChallenge) throws -> HTTPAuthenticationChallenge = { $0 },
        normalize: @escaping @Sendable (HTTPAuthenticationChallenge) throws -> HTTPAuthenticationChallenge = { $0 },
        validate: @escaping @Sendable (HTTPAuthenticationChallenge) throws -> Void = { _ in })
        -> ValuePreparation<HTTPAuthenticationChallenge>
    {
        ValuePreparation(redact: { value in
            try redact(HTTPAuthenticationChallenge(
                method: value.method, host: value.host, port: value.port, protocol: value.protocol, realm: value.realm,
                isProxy: value.isProxy, previousFailureCount: value.previousFailureCount,
                proposedCredential: value.proposedCredential.map(redactCredential)))
        }, normalize: normalize, validate: { value in
            try authenticationUsername.validate(value.proposedCredential?.user)
            try validate(value)
        })
    }

    private func redactCredential(_ value: HTTPAuthenticationCredential) throws -> HTTPAuthenticationCredential {
        try HTTPAuthenticationCredential(
            user: authenticationUsername.redact(value.user), hasPassword: value.hasPassword,
            persistence: value.persistence)
    }
}
