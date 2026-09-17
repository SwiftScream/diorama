import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Atomic single-document storage on a trusted local filesystem.
///
/// Publication writes and closes a private sibling staging file, then commits
/// with POSIX `rename`. Readers opening the destination see one complete old or
/// new document. Concurrent commits accept last-writer-wins behavior. The parent
/// directory must exist; loading never creates it or staging.
///
/// This guarantees visibility atomicity on supported local filesystems, not
/// power-loss durability, metadata preservation, or remote-filesystem behavior.
/// Destinations must be ordinary files or absent; symlink destinations and
/// concurrent in-place editors are outside the contract. Root directories are
/// trusted. Staging cleanup is attempted on every returning path; failures are
/// retained. Process termination can leave private staging directories for
/// caller-managed offline cleanup.
public struct FileScenarioStorage: ScenarioDocumentStorage, Sendable {
    /// The explicit document destination.
    public let location: ScenarioFileLocation

    private let operations: FileStorageOperations

    /// Creates storage without opening files or requiring write permission.
    ///
    /// - Parameter location: Consumer-selected location on a local filesystem.
    public init(location: ScenarioFileLocation) {
        self.init(location: location, operations: FileStorageOperations())
    }

    init(location: ScenarioFileLocation, operations: FileStorageOperations) {
        self.location = location
        self.operations = operations
    }

    /// Reads complete bytes without any publication-side operations.
    ///
    /// - Returns: Bytes, including a zero-byte file, or `nil` for absent content.
    /// - Throws: A safe read failure for errors other than missing content.
    public func load() throws -> Data? {
        do {
            return try operations.read(location.fileURL)
        } catch {
            let code = FileStorageFailureCode(error)
            if code == .posix(Int(ENOENT)) || code == .cocoa(NSFileReadNoSuchFileError) {
                return nil
            }
            throw FileStorageError(operation: .read, cause: code)
        }
    }

    /// Stages and atomically replaces one complete document.
    ///
    /// - Parameter document: Fully encoded bytes; this backend does not decode them.
    /// - Returns: A successful commit receipt with any subsequent cleanup failure.
    /// - Throws: A stage or commit error, including any failed staging cleanup.
    public func publish(_ document: Data) throws -> DocumentPublication {
        let directory = location.fileURL.deletingLastPathComponent()
            .appendingPathComponent(".diorama-stage-\(UUID().uuidString)", isDirectory: true)
        do {
            try operations.createDirectory(directory)
        } catch {
            // Creation did not transfer ownership; never clean someone else's path.
            throw FileStorageError(operation: .stage, cause: FileStorageFailureCode(error))
        }
        let staged = directory.appendingPathComponent("document", isDirectory: false)
        var operation = FileStorageOperation.stage
        do {
            try operations.write(document, staged)
            operation = .commit
            try operations.commit(staged, location.fileURL)
        } catch {
            throw FileStorageError(
                operation: operation,
                cause: FileStorageFailureCode(error),
                cleanupFailure: cleanup(directory))
        }
        if let failure = cleanup(directory) {
            return DocumentPublication(
                cleanupFailure: FileStorageError(operation: .cleanup, cause: failure))
        }
        return DocumentPublication()
    }

    private func cleanup(_ directory: URL) -> FileStorageFailureCode? {
        do {
            try operations.remove(directory)
            return nil
        } catch {
            return FileStorageFailureCode(error)
        }
    }
}

/// Internal operation seams keep fault tests on the production transaction path.
struct FileStorageOperations: Sendable {
    var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    var createDirectory: @Sendable (URL) throws -> Void = {
        try $0.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) }
            // Unlike FileManager, mkdir rejects an already existing directory.
            guard mkdir(path, 0o700) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }

    var write: @Sendable (Data, URL) throws -> Void = {
        try $0.write(to: $1, options: .withoutOverwriting)
    }

    var commit: @Sendable (URL, URL) throws -> Void = { source, destination in
        try source.withUnsafeFileSystemRepresentation { sourcePath in
            try destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
                }
                guard rename(sourcePath, destinationPath) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
        }
    }

    var remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
}
