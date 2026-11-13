import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// POSIX filesystem operations shared by document and resource storage.
/// Descriptor-based reads reject symlinks and nonregular content without FIFO blocking.
/// Trusted root ancestors must not be concurrently replaced by external editors.
enum POSIXFileIO {
    static func createDirectory(_ url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw failure(EINVAL) }
            // Unlike FileManager, mkdir rejects an already existing directory.
            guard mkdir(path, 0o700) == 0 else { throw failure() }
        }
    }

    static func rename(_ source: URL, _ destination: URL) throws {
        try source.withUnsafeFileSystemRepresentation { sourcePath in
            try destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { throw failure(EINVAL) }
                #if canImport(Darwin)
                    let result = Darwin.rename(sourcePath, destinationPath)
                #elseif canImport(Glibc)
                    let result = Glibc.rename(sourcePath, destinationPath)
                #endif
                guard result == 0 else { throw failure() }
            }
        }
    }

    static func directoryExists(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT {
                return false
            }
            throw failure()
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw ScenarioResourceError.unavailable }
        return true
    }

    static func read(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        return try bytes(descriptor)
    }

    static func resource(root: URL, path: ScenarioResourcePath) throws -> Data {
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw failure() }
        defer { close(directory) }
        let parts = path.value.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw failure() }
            close(directory)
            directory = next
        }
        guard let last = parts.last else { throw ScenarioResourceError.invalidPath }
        let file = openat(directory, last, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw failure() }
        return try bytes(file)
    }

    private static func bytes(_ descriptor: Int32) throws -> Data {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ScenarioResourceError.unavailable }
        return try handle.readToEnd() ?? Data()
    }

    private static func failure(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
