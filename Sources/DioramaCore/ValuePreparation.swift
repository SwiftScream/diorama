/// A successfully prepared semantic value, eligible for generic track storage.
///
/// Only ``ValuePreparation`` can create one. Preparation means compliance with
/// the selected policy, not comprehensive removal of personal data. Systems
/// must use stable value semantics; `Sendable` alone does not guarantee that.
public struct PreparedValue<Value: Sendable>: Sendable {
    /// The value after canonicalization, redaction, normalization, and validation.
    public let value: Value

    fileprivate init(_ value: Value) {
        self.value = value
    }
}

/// A transformation stage, ordered by the preparation contract.
public enum PreparationStage: Equatable, Sendable {
    /// Structural changes needed to address fields consistently.
    case canonicalization
    /// Confidentiality transforms before other normalization.
    case redaction
    /// Replacement of volatile values according to setup policy.
    case normalization
    /// Final semantic validation before admission.
    case validation
}

/// Safe failure evidence with no captured value or arbitrary underlying error.
public struct PreparationFailure: Error, Equatable, Sendable {
    /// The exact safe diagnostic retained before this failure is returned.
    public let diagnostic: Diagnostic
}

/// The role of a value being prepared at a system boundary.
public enum PreparationPurpose: Sendable {
    /// An observation for the recording candidate; failure invalidates it.
    case recording
    /// Replay input or baseline content; failure is an infrastructure fact.
    case replay
}

/// Immutable typed policy selected by a system during setup.
///
/// Transformations run synchronously on the caller, outside reporter locks.
/// Native extraction stays in the caller's nonescaping capture closure. Each
/// transform must preserve stable value semantics, be deterministic and
/// idempotent, and avoid logging its input. Defaults intentionally preserve
/// custom values unchanged. Match projection is a separate system concern.
public struct ValuePreparation<Value: Sendable>: Sendable {
    private let canonicalize: @Sendable (Value) throws -> Value
    private let redact: @Sendable (Value) throws -> Value
    private let normalize: @Sendable (Value) throws -> Value
    private let validate: @Sendable (Value) throws -> Void

    /// Creates a setup-owned preparation policy.
    ///
    /// - Parameters:
    ///   - canonicalize: Minimal structural canonicalization before redaction.
    ///   - redact: Confidentiality transformations before normalization.
    ///   - normalize: Volatile-value transformations on redacted input.
    ///   - validate: Final validation of the transformed semantic value.
    public init(canonicalize: @escaping @Sendable (Value) throws -> Value = { $0 },
                redact: @escaping @Sendable (Value) throws -> Value = { $0 },
                normalize: @escaping @Sendable (Value) throws -> Value = { $0 },
                validate: @escaping @Sendable (Value) throws -> Void = { _ in })
    {
        self.canonicalize = canonicalize
        self.redact = redact
        self.normalize = normalize
        self.validate = validate
    }

    /// Captures and prepares one value before generic admission.
    ///
    /// Stops at the first failed stage, retains safe evidence and recording
    /// health before sink notification, and throws only that safe evidence.
    /// No failed value or underlying error is stored or rendered. Adapters
    /// must preserve live dependency behavior on recording failure and must
    /// never use a live fallback on replay failure. Passthrough needs no call.
    ///
    /// - Parameters:
    ///   - capture: Native extraction/conversion in the caller's valid isolation.
    ///   - purpose: The value's recording or replay role.
    ///   - reporter: The current run or startup attempt's diagnostic reporter.
    ///   - context: Stable identity, including any previously reserved position.
    ///   - fieldPath: Safe setup-authored semantic field labels.
    ///   - rule: A safe setup-authored policy identifier.
    /// - Returns: A value eligible for generic scenario storage.
    /// - Throws: ``PreparationFailure`` containing the retained safe diagnostic.
    public func prepare(capturing capture: () throws -> Value,
                        purpose: PreparationPurpose,
                        reporter: DiagnosticReporter,
                        context: DiagnosticContext = .scenario,
                        fieldPath: [DiagnosticLabel] = [],
                        rule: DiagnosticLabel? = nil) throws(PreparationFailure) -> PreparedValue<Value>
    {
        var issue = DiagnosticIssue.conversionFailed
        do {
            var value = try capture()
            issue = .preparationFailed(.canonicalization)
            value = try canonicalize(value)
            issue = .preparationFailed(.redaction)
            value = try redact(value)
            issue = .preparationFailed(.normalization)
            value = try normalize(value)
            issue = .preparationFailed(.validation)
            try validate(value)
            return PreparedValue(value)
        } catch {
            let diagnostic = Diagnostic(
                issue: issue,
                context: context,
                fieldPath: fieldPath,
                rule: rule,
                recordingImpact: purpose == .recording ? .invalidatesCandidate : .none)
            reporter.record(diagnostic)
            throw PreparationFailure(diagnostic: diagnostic)
        }
    }
}
