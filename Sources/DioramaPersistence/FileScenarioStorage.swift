import Foundation

/// Document/resource storage with stable names on a trusted local filesystem.
///
/// `name.json` owns sibling `name-resources/`. Callers must exclude publication
/// from loading, resource resolution, other publication, and manual edits of
/// the same scenario. Independent scenarios and read-only loads may overlap.
/// Loading never writes or requires publication access. Loaded scenario values
/// own resolved bytes; storage snapshots must finish resolving before publication.
///
/// Publication stages all bytes, backs up existing resources, installs the new
/// directory, then atomically replaces the JSON document. Returning failures
/// restore resources; a rollback failure retains staging for caller recovery.
/// Cleanup failures after commit do not undo publication. No crash durability,
/// automatic recovery, or remote-filesystem guarantee is provided. Root ancestors
/// are trusted. Published documents and resource directories must not be symlinks.
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

    /// Stages and atomically replaces one complete document.
    ///
    /// - Parameter document: Fully encoded bytes; this backend does not decode them.
    /// - Returns: A successful commit receipt with any subsequent cleanup failure.
    /// - Throws: A stage or commit error, including any failed staging cleanup.
    private func publishDocumentOnly(_ document: Data) throws -> DocumentPublication {
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

    /// Reads the document without writes; resolve resources before the next publication.
    /// Returns `nil` when the document is absent.
    public func load() throws -> ScenarioDocumentSnapshot? {
        do {
            let data = try operations.read(location.fileURL)
            let root = resourcesURL
            return ScenarioDocumentSnapshot(data: data) { path in
                try POSIXFileIO.resource(root: root, path: path)
            }
        } catch {
            let code = FileStorageFailureCode(error)
            if code == .posix(Int(POSIXError.Code.ENOENT.rawValue)) || code == .cocoa(NSFileReadNoSuchFileError) {
                return nil
            }
            throw FileStorageError(operation: .read, cause: code)
        }
    }

    /// Publishes stable JSON and resource paths under caller-established exclusivity.
    /// Temporary backups are removed only after commit or successful rollback.
    public func publish(_ document: ScenarioDocument) throws -> DocumentPublication {
        let hadResources: Bool
        do { hadResources = try operations.directoryExists(resourcesURL) } catch {
            throw FileStorageError(operation: .stage, cause: FileStorageFailureCode(error))
        }
        guard !document.resources.isEmpty || hadResources else { return try publishDocumentOnly(document.data) }
        let directory = location.fileURL.deletingLastPathComponent()
            .appendingPathComponent(".diorama-stage-\(UUID().uuidString)", isDirectory: true)
        do { try operations.createDirectory(directory) } catch {
            throw FileStorageError(operation: .stage, cause: FileStorageFailureCode(error))
        }
        let stagedResources = directory.appendingPathComponent("resources", isDirectory: true)
        let previousResources = directory.appendingPathComponent("previous-resources", isDirectory: true)
        let stagedDocument = directory.appendingPathComponent("document.json")
        do { try stage(document, in: directory) } catch {
            throw FileStorageError(operation: .stage, cause: FileStorageFailureCode(error),
                                   cleanupFailure: cleanup(directory))
        }
        var backedUp = false
        var installed = false
        do {
            if hadResources {
                try operations.move(resourcesURL, previousResources)
                backedUp = true
            }
            if !document.resources.isEmpty {
                try operations.move(stagedResources, resourcesURL)
                installed = true
            }
            try operations.commit(stagedDocument, location.fileURL)
        } catch {
            let cause = FileStorageFailureCode(error)
            do { try rollback(in: directory, installed: installed, backedUp: backedUp) } catch {
                // Never delete the only backup when restoring it fails.
                throw FileStorageError(operation: .commit, cause: cause,
                                       rollbackFailure: FileStorageFailureCode(error))
            }
            throw FileStorageError(operation: .commit, cause: cause, cleanupFailure: cleanup(directory))
        }
        if let failure = cleanup(directory) {
            return DocumentPublication(cleanupFailure: FileStorageError(operation: .cleanup, cause: failure))
        }
        return DocumentPublication()
    }

    private var resourcesURL: URL {
        let file = location.fileURL
        return file.deletingLastPathComponent()
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-resources", isDirectory: true)
    }

    private func stage(_ document: ScenarioDocument, in directory: URL) throws {
        if !document.resources.isEmpty {
            try writeResources(document.resources, to: directory.appendingPathComponent("resources", isDirectory: true))
        }
        try operations.write(document.data, directory.appendingPathComponent("document.json"))
    }

    private func rollback(in directory: URL, installed: Bool, backedUp: Bool) throws {
        if installed {
            try operations.move(resourcesURL, directory.appendingPathComponent("resources", isDirectory: true))
        }
        if backedUp {
            try operations.move(directory.appendingPathComponent("previous-resources", isDirectory: true), resourcesURL)
        }
    }

    private func writeResources(_ resources: [ScenarioResourcePath: Data], to root: URL) throws {
        try operations.createDirectory(root)
        var created: Set<String> = []
        for path in resources.keys.sorted(by: { $0.value < $1.value }) {
            var directory = root
            var prefix = ""
            let parts = path.value.split(separator: "/")
            for part in parts.dropLast() {
                prefix += String(part) + "/"
                directory.appendPathComponent(String(part), isDirectory: true)
                if created.insert(prefix).inserted {
                    try operations.createDirectory(directory)
                }
            }
            if let bytes = resources[path], let last = parts.last {
                try operations.write(bytes, directory.appendingPathComponent(String(last)))
            }
        }
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
    var read: @Sendable (URL) throws -> Data = { try POSIXFileIO.read($0) }
    var directoryExists: @Sendable (URL) throws -> Bool = { try POSIXFileIO.directoryExists($0) }
    var move: @Sendable (URL, URL) throws -> Void = { try POSIXFileIO.rename($0, $1) }
    var createDirectory: @Sendable (URL) throws -> Void = { try POSIXFileIO.createDirectory($0) }

    var write: @Sendable (Data, URL) throws -> Void = {
        try $0.write(to: $1, options: .withoutOverwriting)
    }

    var commit: @Sendable (URL, URL) throws -> Void = { try POSIXFileIO.rename($0, $1) }

    var remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
}
