import Foundation

/// A rejected repository location without echoing the supplied path.
public enum ScenarioFileLocationError: Error, Equatable, Sendable {
    /// The root is not an absolute local file URL without query or fragment.
    case invalidRoot

    /// The document path is empty, absolute, or contains an unsafe component.
    case invalidRelativePath
}

/// An explicit consumer-selected file location beneath a repository directory.
///
/// The consumer maps its scenario identity to this location. No test name, current
/// directory, locale, or implicit filename sanitization participates. Relative
/// components are literal, case-preserving names; filesystem case and Unicode
/// equivalence still apply. The root and its ancestors must be trusted: lexical
/// path validation does not provide containment against symlinks or mount changes.
public struct ScenarioFileLocation: Equatable, Sendable {
    /// The absolute document URL, suitable for caller-controlled file access.
    public let fileURL: URL

    /// The literal path relative to the configured root.
    ///
    /// This caller-authored value is not automatically safe for diagnostic output.
    public let relativePath: String

    /// Creates a deterministic location without accessing the filesystem.
    ///
    /// The parent directory must already exist before publication. Empty, dot,
    /// dot-dot, backslash, and control-character components are rejected. No
    /// extension is added and percent escapes are treated as literal filename text.
    ///
    /// - Parameters:
    ///   - rootDirectory: An absolute local file URL naming the trusted root.
    ///   - relativePath: Slash-separated document components beneath that root.
    /// - Throws: A path-category error that excludes the supplied path text.
    public init(rootDirectory: URL, relativePath: String) throws(ScenarioFileLocationError) {
        guard rootDirectory.isFileURL, rootDirectory.baseURL == nil,
              rootDirectory.host == nil || rootDirectory.host == "",
              rootDirectory.query == nil, rootDirectory.fragment == nil,
              rootDirectory.path.hasPrefix("/"),
              !rootDirectory.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw .invalidRoot
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !relativePath.contains("\\"),
              !relativePath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw .invalidRelativePath
        }
        fileURL = components.reduce(rootDirectory.standardizedFileURL) { url, component in
            url.appendingPathComponent(String(component), isDirectory: false)
        }
        self.relativePath = relativePath
    }
}
