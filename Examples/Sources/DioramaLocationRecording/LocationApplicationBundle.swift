import Darwin
import Foundation

/// SwiftPM builds a standalone executable. Location authorization on macOS also
/// needs a discoverable app bundle, so the console entry point launches a copy
/// inside an adjacent app bundle while preserving terminal input and output.
enum LocationApplicationBundle {
    /// Replaces the launcher with the bundled recorder, preserving its terminal
    /// process group, standard streams, arguments, and exit status.
    static func launchIfNeeded() throws {
        guard Bundle.main.bundleURL.pathExtension != "app" else { return }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              let metadata = Bundle.main.infoDictionary
        else { throw BundleError.missingExecutableMetadata }

        let app = executable.deletingLastPathComponent().appendingPathComponent("DioramaLocationRecording.app")
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let binaries = contents.appendingPathComponent("MacOS", isDirectory: true)
        let bundledExecutable = binaries.appendingPathComponent(executable.lastPathComponent)
        let files = FileManager.default
        if files.fileExists(atPath: app.path) {
            try files.removeItem(at: app)
        }
        try files.createDirectory(at: binaries, withIntermediateDirectories: true)
        try files.copyItem(at: executable, to: bundledExecutable)
        let plist = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let signing = try run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: [
            "--force", "--sign", "-", app.path,
        ])
        guard signing == 0 else { throw BundleError.signingFailed(signing) }
        let copiedArguments = ([bundledExecutable.path] + CommandLine.arguments.dropFirst()).map { strdup($0) }
        defer { copiedArguments.forEach { free($0) } }
        guard copiedArguments.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        var arguments = copiedArguments + [nil]
        _ = arguments.withUnsafeMutableBufferPointer { execv(bundledExecutable.path, $0.baseAddress) }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func run(_ executable: URL, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
    }
}

private enum BundleError: Error {
    case missingExecutableMetadata
    case signingFailed(Int32)
}
