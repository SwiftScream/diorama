import DioramaCore
import HTTPTypes

/// Immutable field participation rules, applied after preparation and redaction.
public enum HTTPMatchFields: Sendable {
    /// Matches only these fields, without applying default exclusions.
    case including(Set<HTTPField.Name>)
    /// Matches every field except these, without adding default exclusions.
    case excluding(Set<HTTPField.Name>)

    /// Matches all fields except authority/body-derived, connection, and User-Agent fields.
    public static let standard = Self.excluding(defaultExclusions)

    /// Fields excluded by the standard policy; customize with ordinary set operations.
    public static let defaultExclusions: Set<HTTPField.Name> = Set([
        "Host", "Content-Length", "Connection", "Keep-Alive", "Proxy-Connection",
        "Transfer-Encoding", "User-Agent",
    ].compactMap { HTTPField.Name($0) })

    func contains(_ name: HTTPField.Name) -> Bool {
        switch self {
        case let .including(names): names.contains(name)
        case let .excluding(names): !names.contains(name)
        }
    }
}

/// A comparison-only request projection. Construction requires prepared input.
/// Resource bytes are resolved before selection; storage paths have no match meaning.
public struct HTTPRequestMatchProjection: Hashable, Sendable {
    /// Prepared method, without case folding.
    public let method: HTTPRequest.Method
    /// Prepared scheme, without additional normalization.
    public let scheme: String?
    /// Prepared authority, without additional normalization.
    public let authority: String?
    /// Prepared path and query, preserving literal ordering.
    public let path: String?
    /// Logical bytes; nil means absent and an empty array means present-empty.
    public let body: [UInt8]?
    /// Participating names and ordered byte values, without case-sensitive name identity.
    public let fields: [HTTPField.Name: [[UInt8]]]

    fileprivate init(_ request: HTTPRequestMessage, fields policy: HTTPMatchFields, body: [UInt8]?) {
        method = request.head.method
        scheme = request.head.scheme
        authority = request.head.authority
        path = request.head.path
        self.body = body
        var fields: [HTTPField.Name: [[UInt8]]] = [:]
        for field in request.head.headerFields where policy.contains(field.name) {
            fields[field.name, default: []].append(field.withUnsafeBytesOfValue { Array($0) })
        }
        self.fields = fields
    }
}

/// Safe component differences, containing no captured names, values, bytes, or paths.
public enum HTTPRequestDifference: String, CaseIterable, Sendable {
    /// Prepared methods differ.
    case method
    /// Prepared schemes differ.
    case scheme
    /// Prepared authorities differ.
    case authority
    /// Prepared paths or query strings differ.
    case path
    /// Logical bodies differ, including presence.
    case body
    /// Participating field names or ordered byte values differ.
    case fields
    /// A consumer-supplied comparison rejects otherwise identical projections.
    case custom

    var label: DiagnosticLabel {
        switch self {
        case .method: DiagnosticLabel("http.request.method")
        case .scheme: DiagnosticLabel("http.request.scheme")
        case .authority: DiagnosticLabel("http.request.authority")
        case .path: DiagnosticLabel("http.request.path")
        case .body: DiagnosticLabel("http.request.body")
        case .fields: DiagnosticLabel("http.request.fields")
        case .custom: DiagnosticLabel("http.request.custom")
        }
    }
}

/// Safe projection failures. Resolver errors never escape with resource details.
public enum HTTPMatchProjectionError: Error, Equatable, Sendable {
    /// No logical bytes could be obtained for a resource-backed body.
    case resourceUnavailable
}

/// Setup-owned matching over prepared HTTP projections.
///
/// Projection is separate from preparation and does not modify stored messages.
/// Custom comparisons must be pure, deterministic equivalence relations. Use a
/// custom Core selector when a policy needs to report unresolved ambiguity.
public struct HTTPRequestMatcher: Sendable {
    private let fields: HTTPMatchFields
    private let rule: DiagnosticLabel
    private let compare: @Sendable (HTTPRequestMatchProjection, HTTPRequestMatchProjection) -> Bool

    /// Creates the standard exact projection matcher with configurable field participation.
    public init(fields: HTTPMatchFields = .standard) {
        self.fields = fields
        rule = DiagnosticLabel("http.standard")
        compare = { $0 == $1 }
    }

    /// Creates a typed comparison over prepared, resolved projections.
    public init(
        fields: HTTPMatchFields = .standard,
        rule: DiagnosticLabel = DiagnosticLabel("http.custom"),
        matches: @escaping @Sendable (HTTPRequestMatchProjection, HTTPRequestMatchProjection) -> Bool)
    {
        self.fields = fields
        self.rule = rule
        compare = matches
    }

    /// Projects an admitted request, resolving resource content through controlled setup.
    /// The resolver must read only prepared scenario content, never a live dependency.
    public func project(
        _ request: PreparedValue<HTTPRequestMessage>,
        resolve: (HTTPBodyResource) throws -> [UInt8] = { _ in throw HTTPMatchProjectionError.resourceUnavailable })
        throws(HTTPMatchProjectionError) -> HTTPRequestMatchProjection
    {
        let body: [UInt8]?
        switch request.value.body {
        case .absent: body = nil
        case let .bytes(bytes): body = bytes
        case let .resource(resource):
            do { body = try resolve(resource) } catch { throw .resourceUnavailable }
        }
        return HTTPRequestMatchProjection(request.value, fields: fields, body: body)
    }

    /// Compares projections created with this setup's field policy.
    public func matches(_ lhs: HTTPRequestMatchProjection, _ rhs: HTTPRequestMatchProjection) -> Bool {
        compare(lhs, rhs)
    }

    /// Reports differing components in fixed order; custom equivalence suppresses differences.
    public func differences(
        _ lhs: HTTPRequestMatchProjection,
        _ rhs: HTTPRequestMatchProjection) -> [HTTPRequestDifference]
    {
        guard !matches(lhs, rhs) else { return [] }
        var result: [HTTPRequestDifference] = []
        if lhs.method != rhs.method {
            result.append(.method)
        }
        if lhs.scheme != rhs.scheme {
            result.append(.scheme)
        }
        if lhs.authority != rhs.authority {
            result.append(.authority)
        }
        if lhs.path != rhs.path {
            result.append(.path)
        }
        if lhs.body != rhs.body {
            result.append(.body)
        }
        if lhs.fields != rhs.fields {
            result.append(.fields)
        }
        return result.isEmpty ? [.custom] : result
    }

    /// Builds a Core selector over already-projected records, with equivalent FIFO claims.
    /// No-match and exhausted claims retain only fixed safe component labels.
    public func selector<Value: Sendable>(
        recordedInput: @escaping @Sendable (Value) -> HTTPRequestMatchProjection)
        -> ReplaySelector<HTTPRequestMatchProjection, Value>
    {
        ReplaySelector(rule: rule, differences: { input, records in
            let differences = Set(records.flatMap { self.differences(input, recordedInput($0.value)) })
            return HTTPRequestDifference.allCases.filter(differences.contains).map(\.label)
        }, select: { input, records in
            let matches = records.filter { self.matches(input, recordedInput($0.value)) }.map(\.identity)
            return matches.isEmpty ? .noMatch : .equivalent(matches)
        })
    }
}
