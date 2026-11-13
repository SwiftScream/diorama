import Foundation

/// The file operation that failed, without native descriptions or paths.
public enum FileStorageOperation: Equatable, Sendable {
    /// Read the published document.
    case read
    /// Create or write unpublished staging.
    case stage
    /// Install resources or replace the JSON destination.
    case commit
    /// Remove this publication's private staging directory.
    case cleanup
}

/// Bounded native error evidence without arbitrary user info or descriptions.
public enum FileStorageFailureCode: Equatable, Sendable {
    /// A POSIX error number.
    case posix(Int)
    /// A Foundation Cocoa error number.
    case cocoa(Int)
    /// A failure outside the supported native error domains.
    case other

    init(_ error: any Error) {
        let native = error as NSError
        switch native.domain {
        case NSPOSIXErrorDomain: self = .posix(native.code)
        case NSCocoaErrorDomain: self = .cocoa(native.code)
        default: self = .other
        }
    }
}

/// File failure evidence preserving both the primary and any cleanup failure.
///
/// A thrown stage or commit failure preserves the previous publication unless
/// resource rollback also fails. In that case staging retains recovery bytes.
/// Cleanup failures after commit are returned in ``DocumentPublication`` instead.
public struct FileStorageError: Error, Equatable, Sendable {
    /// The failed operation.
    public let operation: FileStorageOperation
    /// Safe native error evidence for that operation.
    public let cause: FileStorageFailureCode
    /// Additional failure while removing unpublished staging, if any.
    public let cleanupFailure: FileStorageFailureCode?

    /// Failure restoring the prior resources; retained staging requires caller recovery.
    public let rollbackFailure: FileStorageFailureCode?

    init(operation: FileStorageOperation, cause: FileStorageFailureCode,
         cleanupFailure: FileStorageFailureCode? = nil, rollbackFailure: FileStorageFailureCode? = nil)
    {
        self.operation = operation
        self.cause = cause
        self.cleanupFailure = cleanupFailure
        self.rollbackFailure = rollbackFailure
    }
}
