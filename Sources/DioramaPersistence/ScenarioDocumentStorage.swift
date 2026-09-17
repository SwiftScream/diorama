import Foundation

/// Storage for one complete encoded scenario, independent of its semantic codec.
///
/// Operations are synchronous and may block the caller. Loading must not write,
/// create directories, or require publication access. Publication must make the
/// complete document visible atomically and accept last-committer-wins writes.
/// A thrown publication error means no commit occurred; cleanup failures after
/// commit belong in the returned receipt. Backends must document their limits.
public protocol ScenarioDocumentStorage: Sendable {
    /// Reads complete document bytes, or returns `nil` when content is absent.
    func load() throws -> Data?

    /// Publishes complete bytes and reports any subsequent cleanup failure.
    ///
    /// - Parameter document: Fully encoded candidate bytes.
    /// - Returns: Evidence that the commit succeeded, including cleanup status.
    func publish(_ document: Data) throws -> DocumentPublication
}

/// Evidence of a completed storage commit, independent of cleanup success.
public struct DocumentPublication: Sendable {
    /// Cleanup evidence after commit; never implies that publication was undone.
    public let cleanupFailure: (any Error)?

    /// Creates a receipt for an already completed commit.
    ///
    /// - Parameter cleanupFailure: Safe backend-owned cleanup evidence, if any.
    public init(cleanupFailure: (any Error)? = nil) {
        self.cleanupFailure = cleanupFailure
    }
}
