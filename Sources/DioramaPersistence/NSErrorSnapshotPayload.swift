import DioramaCore
import Foundation

/// Shared opt-in persisted form of a bounded error snapshot.
/// Systems retain ownership of metadata policy and their versioned payload schemas.
package struct NSErrorSnapshotPayload: Codable, Sendable {
    private let domain: String
    private let code: Int
    private let userInfo: [String: NSErrorSnapshotValuePayload]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case domain, code, userInfo
    }

    /// Copies an already validated snapshot into its persisted representation.
    package init(_ snapshot: NSErrorSnapshot) {
        domain = snapshot.domain
        code = snapshot.code
        userInfo = snapshot.userInfo.mapValues(NSErrorSnapshotValuePayload.init)
    }

    /// Decodes strict tagged values and validates the complete bounded snapshot.
    package init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        domain = try fields.decode(String.self, forKey: .domain)
        code = try fields.decode(Int.self, forKey: .code)
        userInfo = try fields.decode([String: NSErrorSnapshotValuePayload].self, forKey: .userInfo)
        _ = try snapshot()
    }

    /// Writes the shared representation without rounding error metadata.
    package func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(domain, forKey: .domain)
        try fields.encode(code, forKey: .code)
        try fields.encode(userInfo, forKey: .userInfo)
    }

    /// Returns the validated semantic value for use by the owning system.
    package func snapshot() throws -> NSErrorSnapshot {
        guard let value = NSErrorSnapshot(
            domain: domain, code: code, userInfo: userInfo.mapValues(\.snapshot))
        else {
            throw NSErrorSnapshotPayloadError.invalidBounds
        }
        return value
    }
}

private enum NSErrorSnapshotPayloadError: Error, Equatable, Sendable {
    case invalidBounds
    case invalidDate
}

private indirect enum NSErrorSnapshotValuePayload: Codable, Sendable {
    case string(String)
    case integer(Int64)
    case real(Double)
    case boolean(Bool)
    case data(Data)
    case date(Date)
    case array([Self])
    case dictionary([String: Self])

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type, value
    }

    private enum Kind: String, Codable {
        case string, integer, real, boolean, data, date, array, dictionary
    }

    init(_ value: NSErrorSnapshotValue) {
        switch value {
        case let .string(value): self = .string(value)
        case let .integer(value): self = .integer(value)
        case let .real(value): self = .real(value)
        case let .boolean(value): self = .boolean(value)
        case let .data(value): self = .data(value)
        case let .date(value): self = .date(value)
        case let .array(value): self = .array(value.map(Self.init))
        case let .dictionary(value): self = .dictionary(value.mapValues(Self.init))
        }
    }

    var snapshot: NSErrorSnapshotValue {
        switch self {
        case let .string(value): .string(value)
        case let .integer(value): .integer(value)
        case let .real(value): .real(value)
        case let .boolean(value): .boolean(value)
        case let .data(value): .data(value)
        case let .date(value): .date(value)
        case let .array(value): .array(value.map(\.snapshot))
        case let .dictionary(value): .dictionary(value.mapValues(\.snapshot))
        }
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        switch try fields.decode(Kind.self, forKey: .type) {
        case .string: self = try .string(fields.decode(String.self, forKey: .value))
        case .integer: self = try .integer(fields.decode(Int64.self, forKey: .value))
        case .real: self = try .real(Self.decodeReal(fields))
        case .boolean: self = try .boolean(fields.decode(Bool.self, forKey: .value))
        case .data: self = try .data(fields.decode(Data.self, forKey: .value))
        case .date: self = try .date(Self.decodeDate(fields))
        case .array: self = try .array(fields.decode([Self].self, forKey: .value))
        case .dictionary: self = try .dictionary(fields.decode([String: Self].self, forKey: .value))
        }
    }

    private static func decodeReal(_ fields: KeyedDecodingContainer<CodingKeys>) throws -> Double {
        let value = try fields.decode(Double.self, forKey: .value)
        guard value.isFinite else { throw NSErrorSnapshotPayloadError.invalidBounds }
        return value == 0 ? 0 : value
    }

    private static func decodeDate(_ fields: KeyedDecodingContainer<CodingKeys>) throws -> Date {
        let seconds = try fields.decode(Double.self, forKey: .value)
        guard seconds.isFinite else { throw NSErrorSnapshotPayloadError.invalidDate }
        let date = Date(timeIntervalSince1970: seconds)
        guard StableTimeCodec.roundedToMillisecond(date) != nil else {
            throw NSErrorSnapshotPayloadError.invalidDate
        }
        return date
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value):
            try fields.encode(Kind.string, forKey: .type)
            try fields.encode(value, forKey: .value)
        case let .integer(value):
            try fields.encode(Kind.integer, forKey: .type)
            try fields.encode(value, forKey: .value)
        case let .real(value):
            try fields.encode(Kind.real, forKey: .type)
            try fields.encode(value == 0 ? 0 : value, forKey: .value)
        case let .boolean(value):
            try fields.encode(Kind.boolean, forKey: .type)
            try fields.encode(value, forKey: .value)
        case let .data(value):
            try fields.encode(Kind.data, forKey: .type)
            try fields.encode(value, forKey: .value)
        case let .date(value):
            guard StableTimeCodec.roundedToMillisecond(value) != nil else {
                throw NSErrorSnapshotPayloadError.invalidDate
            }
            try fields.encode(Kind.date, forKey: .type)
            try fields.encode(value.timeIntervalSince1970, forKey: .value)
        case let .array(value):
            try fields.encode(Kind.array, forKey: .type)
            try fields.encode(value, forKey: .value)
        case let .dictionary(value):
            try fields.encode(Kind.dictionary, forKey: .type)
            try fields.encode(value, forKey: .value)
        }
    }
}
