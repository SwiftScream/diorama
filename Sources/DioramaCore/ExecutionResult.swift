/// Safe execution-lifetime facts without arbitrary callback errors.
public enum ScenarioLifecycleIssue: Equatable, Sendable {
    /// Registrations do not identify every declared attachment exactly once,
    /// or runtime policy references an attachment outside that layout.
    case invalidRegistration
    /// A system's preparation callback failed.
    case preparationFailed
    /// A declared track did not receive a preparation policy and lease.
    case unpreparedTrack
    /// A track request is missing, incompatible, or repeated.
    case invalidTrackRequest
    /// A preparation context was used after its callback returned.
    case preparationClosed
    /// A system's activation callback failed.
    case activationFailed
    /// An activated system's cleanup callback failed.
    case cleanupFailed
    /// A closed lease was used to submit an active-system diagnostic.
    case leaseClosed
    /// A dependency was requested after execution admission closed.
    case executionClosed
    /// No activated dependency has the requested key and type.
    case invalidDependencyRequest
}

/// One activated attachment's cleanup outcome, independent of test policy.
public struct AttachmentCleanup: Equatable, Sendable {
    /// The system instance whose callback was invoked.
    public let attachmentID: AttachmentID
    /// The callback's completion disposition.
    public let disposition: Disposition

    /// Whether the adapter reports successful cleanup.
    public enum Disposition: Equatable, Sendable {
        /// Cleanup returned successfully.
        case completed
        /// Cleanup threw; other attachments still receive cleanup.
        case failed
    }
}

/// An immutable result of explicit in-memory execution finalization.
///
/// Usage and safe diagnostics contain no recorded values or live resources.
/// Evaluation is an explicit consumer action, independent of test frameworks.
public struct ScenarioFinalizationResult: Equatable, Sendable {
    /// Diagnostics and recording health through the result's freeze boundary.
    public let report: DiagnosticReport
    /// Cleanup outcomes in attachment order, not callback completion order.
    public let cleanup: [AttachmentCleanup]
    /// Active attachments in setup order.
    public let usage: [AttachmentUsage]
}

/// The body and finalization outcomes from one scoped scenario execution.
///
/// A body failure is a value so it cannot hide the immutable finalization
/// result. Startup still throws ``ScenarioStartupFailure`` because no running
/// execution or finalization result exists when startup fails.
public struct ScopedExecutionResult<Success: Sendable, Failure: Error>: Sendable {
    /// The value returned or error thrown by the scoped body.
    public let body: Result<Success, Failure>

    /// The result produced after the body stopped executing.
    public let finalization: ScenarioFinalizationResult
}

extension ScopedExecutionResult: Equatable where Success: Equatable, Failure: Equatable {}

/// A safe, already-reported dependency lookup failure.
public struct DependencyAccessFailure: Error, Equatable, Sendable {
    /// The retained lookup diagnostic, without a native dependency or error.
    public let diagnostic: Diagnostic
}
