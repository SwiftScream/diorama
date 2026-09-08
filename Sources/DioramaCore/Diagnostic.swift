/// A setup-authored label that cannot be initialized from a runtime payload.
///
/// Use labels for safe rule names, semantic field paths, and system issue codes.
/// Literal text is still consumer-authored: do not place secrets in it.
public struct DiagnosticLabel: Hashable, Sendable {
    /// The literal label text.
    public let text: String

    /// Creates a label from static source text.
    ///
    /// - Parameter text: A safe semantic label, never a captured value.
    public init(_ text: StaticString) {
        self.text = text.description
    }
}

/// The most specific stable identity relevant to a diagnostic.
///
/// Ancestor identities derive from the selected case and cannot contradict it.
/// Identity strings must be safe setup-authored identifiers, not native data.
public enum DiagnosticContext: Equatable, Sendable {
    /// A fact about the whole scenario.
    case scenario
    /// A fact about an attached system instance.
    case attachment(AttachmentID)
    /// A fact about a track within an attached system.
    case track(TrackID)
    /// A fact about a particular record or reserved record position.
    case record(RecordIdentity)

    /// The relevant system attachment, when present.
    public var attachmentID: AttachmentID? {
        switch self {
        case .scenario: nil
        case let .attachment(id): id
        case let .track(id): id.attachmentID
        case let .record(id): id.trackID.attachmentID
        }
    }

    /// The relevant track, when present.
    public var trackID: TrackID? {
        switch self {
        case .scenario, .attachment: nil
        case let .track(id): id
        case let .record(id): id.trackID
        }
    }

    /// The relevant record, when present.
    public var recordIdentity: RecordIdentity? {
        if case let .record(identity) = self {
            identity
        } else {
            nil
        }
    }
}

/// An infrastructure or verification fact, independent of dependency errors.
public enum DiagnosticIssue: Equatable, Sendable {
    /// Native extraction or stable conversion failed before preparation.
    case conversionFailed
    /// A configured preparation stage failed.
    case preparationFailed(PreparationStage)
    /// A sink threw while receiving an already retained diagnostic.
    case sinkFailed
    /// A system-defined infrastructure or verification fact.
    case system(DiagnosticLabel)
}

/// The effect of one infrastructure fact on recording completeness.
public enum RecordingImpact: Equatable, Sendable {
    /// The fact does not invalidate the recording candidate.
    case none
    /// The candidate cannot be published as a healthy recording.
    case invalidatesCandidate
}

/// Safe structured context delivered to diagnostics consumers.
///
/// No raw payload, arbitrary error, runtime type description, or test outcome
/// is retained. Field and rule labels describe semantics, never field values.
public struct Diagnostic: Equatable, Sendable {
    /// The infrastructure or verification fact.
    public let issue: DiagnosticIssue
    /// Its most specific relevant identity.
    public let context: DiagnosticContext
    /// Safe semantic field labels, in path order.
    public let fieldPath: [DiagnosticLabel]
    /// The setup-authored rule identifier, when relevant.
    public let rule: DiagnosticLabel?
    /// Whether this fact makes the candidate unsuitable for publication.
    public let recordingImpact: RecordingImpact

    /// Creates a structured diagnostic without rendering runtime values.
    ///
    /// - Parameters:
    ///   - issue: The infrastructure or verification fact.
    ///   - context: Its stable identity context.
    ///   - fieldPath: Safe semantic labels in path order.
    ///   - rule: A safe setup-authored rule identifier.
    ///   - recordingImpact: The effect on recording health.
    public init(issue: DiagnosticIssue,
                context: DiagnosticContext = .scenario,
                fieldPath: [DiagnosticLabel] = [],
                rule: DiagnosticLabel? = nil,
                recordingImpact: RecordingImpact = .none)
    {
        self.issue = issue
        self.context = context
        self.fieldPath = fieldPath
        self.rule = rule
        self.recordingImpact = recordingImpact
    }
}

/// A retained diagnostic with its admission order within one reporter.
public struct ReportedDiagnostic: Equatable, Sendable {
    /// A zero-based sequence shared by the active and post-finish logs.
    public let sequence: UInt64
    /// The safe diagnostic recorded at this position.
    public let diagnostic: Diagnostic
}

/// Recording completeness facts, without a test pass/fail judgment.
public struct RecordingHealth: Equatable, Sendable {
    /// Retained facts that invalidate this recording candidate.
    public let failures: [ReportedDiagnostic]
    /// Whether no reported fact has invalidated the candidate.
    public var isHealthy: Bool {
        failures.isEmpty
    }
}

/// An immutable diagnostic snapshot and its associated recording health.
public struct DiagnosticReport: Equatable, Sendable {
    /// The scenario whose facts are reported.
    public let scenarioID: ScenarioID
    /// Facts in attachment, track, record, then admission order.
    public let diagnostics: [ReportedDiagnostic]
    /// Candidate health derived from exactly this snapshot's diagnostics.
    public var recordingHealth: RecordingHealth {
        RecordingHealth(failures: diagnostics.filter { $0.diagnostic.recordingImpact == .invalidatesCandidate })
    }
}

/// Safe diagnostic evidence for a startup attempt that yields no execution.
///
/// Activation and rollback add their disposition at the execution boundary.
/// This error carries no arbitrary underlying error or partially active system.
public struct ScenarioStartupFailure: Error, Equatable, Sendable {
    /// The startup attempt's retained diagnostic evidence.
    public let report: DiagnosticReport

    /// Creates a startup failure from an immutable diagnostic snapshot.
    ///
    /// - Parameter report: The evidence collected during the failed attempt.
    public init(report: DiagnosticReport) {
        self.report = report
    }
}
