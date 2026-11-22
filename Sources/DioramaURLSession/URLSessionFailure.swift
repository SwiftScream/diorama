import DioramaCore
import DioramaPersistence
import Foundation

/// Stable URLSession dependency failure, independent of a native error object.
///
/// Use this as the failure parameter of shared HTTP lifecycle values. This is
/// neither a universal HTTP failure nor a Diorama infrastructure error. Constructing
/// a value does not prepare it; capture and authored admission use `ValuePreparation`.
/// Metadata uses Core's bounded snapshot rules without interpreting native keys.
public struct URLSessionFailure: Equatable, Sendable {
    let snapshot: NSErrorSnapshot

    /// Original NSError domain, bounded to 256 UTF-8 bytes.
    public var domain: String {
        snapshot.domain
    }

    /// Original numeric code, including unrecognized URL-loading codes.
    public var code: Int {
        snapshot.code
    }

    /// Creates a structurally valid failure with no user information.
    public init(domain: String, code: Int) throws {
        guard let snapshot = NSErrorSnapshot(domain: domain, code: code) else {
            throw URLSessionFailureError.invalidSnapshot
        }
        self.init(snapshot: snapshot)
    }

    init(snapshot: NSErrorSnapshot) {
        self.snapshot = snapshot
    }

    /// Reconstructs a fresh native error with the supported stable semantics.
    ///
    /// URL-domain errors are explicitly wrapped in `URLError`; other domains
    /// return `NSError`. Unknown numeric codes remain intact.
    /// Supported user information is restored, including explicit description strings.
    /// The original object, subclass, and underlying error graph are not restored.
    public func makeError() -> any Error {
        let error = snapshot.makeError()
        if error.domain == NSURLErrorDomain {
            return URLError(_nsError: error)
        }
        return error
    }

    /// Extracts and prepares a native dependency error before recording admission.
    ///
    /// Core's structural snapshot rules apply to every native key and error domain.
    /// Supported strings and URLs are preserved by default; preparation owns redaction.
    /// Unsupported entries produce key/type-only omission facts with no recording
    /// impact. Conversion or preparation failure invalidates the candidate and
    /// throws safe `PreparationFailure` evidence. Callers always forward the original
    /// live error, even if capture fails. Passthrough does not need capture.
    ///
    /// The caller must classify observed task cancellation as runtime control
    /// before calling this method. A dependency-originated cancellation is recordable;
    /// the numeric canceled code alone cannot establish the source of cancellation.
    public static func capture(
        _ error: any Error,
        preparation: ValuePreparation<Self> = ValuePreparation(),
        reporter: DiagnosticReporter,
        context: DiagnosticContext = .scenario) throws(PreparationFailure) -> PreparedValue<Self>
    {
        try preparation.prepare(capturing: {
            let capture = NSErrorSnapshot.capture(error as NSError)
            for omission in capture.omissions {
                reporter.record(Diagnostic(
                    issue: .nativeErrorMetadataOmitted(key: omission.key, runtimeType: omission.runtimeType),
                    context: context, fieldPath: [DiagnosticLabel("failure"), DiagnosticLabel("userInfo")]))
            }
            guard let snapshot = capture.snapshot else { throw URLSessionFailureError.invalidSnapshot }
            return Self(snapshot: snapshot)
        }, purpose: .recording, reporter: reporter, context: context,
        fieldPath: [DiagnosticLabel("failure")])
    }
}

/// Structural construction or decoding errors, distinct from dependency failures.
public enum URLSessionFailureError: Error, Equatable, Sendable {
    /// Domain or bounded snapshot values are invalid.
    case invalidSnapshot
    /// Underlying decoding error for an unsupported failure component schema version.
    case unsupportedVersion
}

extension URLSessionFailure: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, error
    }

    /// Decodes the strict version-one component using the shared bounded error payload.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        guard try fields.decode(Int.self, forKey: .version) == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: fields.codingPath + [CodingKeys.version],
                                                    debugDescription: "Unsupported URLSession failure version",
                                                    underlyingError: URLSessionFailureError.unsupportedVersion))
        }
        let snapshot = try fields.decode(NSErrorSnapshotPayload.self, forKey: .error).snapshot()
        self.init(snapshot: snapshot)
    }

    /// Encodes only prepared semantic content; this does not run confidentiality transforms.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(1, forKey: .version)
        try fields.encode(NSErrorSnapshotPayload(snapshot), forKey: .error)
    }
}
