import DioramaCore
import DioramaHTTP
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Native extraction into the portable authentication components.
///
/// These helpers do not wire callbacks, perform authentication, or reconstruct
/// secrets. Default preparation replaces nonempty usernames with `redacted` in
/// proposed and selected credentials. Setup can select another shared username
/// rule through `HTTPPreparation`. Original live values remain untouched.
public enum URLSessionAuthentication {
    /// Captures a supported response-backed Basic/Digest challenge and prepares it.
    ///
    /// The native failure response must be the same 401/407 head owned by the
    /// lifecycle node. This helper checks its status without copying it into metadata.
    /// On failure, callers forward live behavior and refuse recording publication.
    public static func capture(
        _ challenge: URLAuthenticationChallenge,
        preparation: ValuePreparation<HTTPAuthenticationChallenge> = HTTPPreparation().authenticationChallenge(),
        reporter: DiagnosticReporter,
        context: DiagnosticContext = .scenario) throws(PreparationFailure) -> PreparedValue<HTTPAuthenticationChallenge>
    {
        try preparation.prepare(capturing: {
            let space = challenge.protectionSpace
            let method: HTTPAuthenticationMethod
            switch space.authenticationMethod {
            case NSURLAuthenticationMethodHTTPBasic: method = .basic
            case NSURLAuthenticationMethodHTTPDigest: method = .digest
            default: throw URLSessionAuthenticationError.unsupportedMethod
            }
            guard let response = challenge.failureResponse as? HTTPURLResponse,
                  response.statusCode == (space.isProxy() ? 407 : 401)
            else {
                throw URLSessionAuthenticationError.unsupportedResponse
            }
            return try HTTPAuthenticationChallenge(
                method: method, host: space.host, port: space.port, protocol: space.protocol, realm: space.realm,
                isProxy: space.isProxy(), previousFailureCount: challenge.previousFailureCount,
                proposedCredential: challenge.proposedCredential.map(metadata))
        }, purpose: .recording, reporter: reporter, context: context, fieldPath: [DiagnosticLabel("authentication")])
    }

    /// Converts a current disposition and prepares only the credential metadata it uses.
    ///
    /// The same identity policy must prepare recorded use-credential answers and live
    /// replay answers. Password contents are never read or compared. An irrelevant
    /// credential supplied with a different disposition is ignored, as Foundation does.
    /// Preparation receives metadata only, so it cannot validate password contents.
    /// Consumers test correct password entry or selection outside this replay boundary.
    public static func decision(
        _ disposition: URLSession.AuthChallengeDisposition,
        credential: URLCredential?,
        preparation: ValuePreparation<HTTPAuthenticationCredential> = HTTPPreparation().authenticationCredential(),
        purpose: PreparationPurpose,
        reporter: DiagnosticReporter,
        context: DiagnosticContext = .scenario) throws(PreparationFailure) -> HTTPAuthenticationDecision
    {
        switch disposition {
        case .useCredential:
            let value = try preparation.prepare(capturing: {
                guard let credential else { throw URLSessionAuthenticationError.missingCredential }
                return try metadata(credential)
            }, purpose: purpose, reporter: reporter, context: context,
            fieldPath: [
                DiagnosticLabel("authentication"),
                DiagnosticLabel("credential"),
            ])
            return .useCredential(value.value)
        case .performDefaultHandling: return .performDefaultHandling
        case .rejectProtectionSpace: return .rejectProtectionSpace
        case .cancelAuthenticationChallenge: return .cancel
        @unknown default:
            return try ValuePreparation<HTTPAuthenticationDecision>().prepare(capturing: {
                throw URLSessionAuthenticationError.unsupportedDisposition
            }, purpose: purpose, reporter: reporter, context: context,
            fieldPath: [
                DiagnosticLabel("authentication"),
                DiagnosticLabel("decision"),
            ]).value
        }
    }

    private static func metadata(_ credential: URLCredential) throws -> HTTPAuthenticationCredential {
        let persistence: HTTPAuthenticationPersistence
        switch credential.persistence {
        case .none: persistence = .none
        case .forSession: persistence = .forSession
        case .permanent: persistence = .permanent
        case .synchronizable: persistence = .synchronizable
        @unknown default: throw URLSessionAuthenticationError.unsupportedPersistence
        }
        return HTTPAuthenticationCredential(user: credential.user, hasPassword: credential.hasPassword,
                                            persistence: persistence)
    }
}

/// Safe extraction errors without native descriptions or credential contents.
public enum URLSessionAuthenticationError: Error, Equatable, Sendable {
    /// Only HTTP Basic and Digest are representable.
    case unsupportedMethod
    /// A matching HTTP origin 401 or proxy 407 response is required.
    case unsupportedResponse
    /// A use-credential answer must supply a credential.
    case missingCredential
    /// The native disposition is unknown to this schema.
    case unsupportedDisposition
    /// The native persistence policy is unknown to this schema.
    case unsupportedPersistence
}
