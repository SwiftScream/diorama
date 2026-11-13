import Foundation

/// Storage for one complete encoded scenario, independent of its semantic codec.
///
/// Operations are synchronous and may block the caller. Loading must not write,
/// create directories, or require publication access. Publication must make the
/// complete document/resource set visible before returning success. Callers must
/// exclude publication from loading (including resource resolution), publication,
/// and manual edits of the same scenario unless a backend promises more.
/// Backends document rollback and crash limits. Cleanup failures after commit
/// belong in the returned receipt.
public protocol ScenarioDocumentStorage: Sendable {
    /// Reads one document and its resource resolver. Resolve before publication resumes.
    /// Returns `nil` when the document is absent.
    func load() throws -> ScenarioDocumentSnapshot?

    /// Publishes a complete logical document/resource set under caller-established exclusivity.
    ///
    /// Backends without resource support must reject nonempty resources before writing.
    /// - Returns: Evidence that the commit succeeded, including cleanup status.
    func publish(_ document: ScenarioDocument) throws -> DocumentPublication
}

/// Evidence of a completed storage commit, independent of cleanup success.
public struct DocumentPublication: Sendable {
    /// Cleanup evidence after commit; never implies that publication was undone.
    public let cleanupFailure: any Error?

    /// Creates a receipt for an already completed commit.
    ///
    /// - Parameter cleanupFailure: Safe backend-owned cleanup evidence, if any.
    public init(cleanupFailure: any Error? = nil) {
        self.cleanupFailure = cleanupFailure
    }
}
