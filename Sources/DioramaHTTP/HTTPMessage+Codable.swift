import DioramaCore
import DioramaPersistence
import Foundation
import HTTPTypes

/// These representations belong to Diorama, independently of HTTPTypes.Codable.
struct FieldPayload: Codable {
    let name: String
    let value: String

    enum CodingKeys: String, CodingKey, CaseIterable { case name, value }

    init(_ field: HTTPField) {
        name = field.name.rawName
        value = field.withUnsafeBytesOfValue { bytes in
            String(String.UnicodeScalarView(bytes.map { UnicodeScalar($0) }))
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
    }

    func field() throws -> HTTPField {
        guard let name = HTTPField.Name(name), value.unicodeScalars.allSatisfy({ $0.value <= 255 }) else {
            throw HTTPMessageError.invalidField
        }
        let bytes = value.unicodeScalars.map { UInt8($0.value) }
        guard HTTPField.isValidValue(bytes) else { throw HTTPMessageError.invalidField }
        return HTTPField(name: name, value: bytes)
    }
}

extension HTTPRequestMessage: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case method, scheme, authority, path, fields, body
    }

    /// Reads the strict Diorama message shape, rejecting unsupported content.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        guard let method = try HTTPRequest.Method(container.decode(String.self, forKey: .method)) else {
            throw HTTPMessageError.invalidHead
        }
        func target(_ key: CodingKeys) throws -> String? {
            guard container.contains(key) else { return nil }
            let value = try container.decode(String.self, forKey: key)
            guard HTTPField.isValidValue(value) else { throw HTTPMessageError.invalidField }
            return value
        }
        let head = try HTTPRequest(
            method: method, scheme: target(.scheme), authority: target(.authority), path: target(.path),
            headerFields: HTTPFields(container.decode([FieldPayload].self, forKey: .fields)
                .map { try $0.field() }))
        try self.init(head: head, body: container.decode(HTTPRequestBody.self, forKey: .body))
    }

    /// Writes explicit method/target/field/body keys, never dependency Codable.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(head.method.rawValue, forKey: .method)
        try container.encodeIfPresent(head.scheme, forKey: .scheme)
        try container.encodeIfPresent(head.authority, forKey: .authority)
        try container.encodeIfPresent(head.path, forKey: .path)
        try container.encode(head.headerFields.map(FieldPayload.init), forKey: .fields)
        try container.encode(body, forKey: .body)
    }
}

extension HTTPResponseHead: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case status, reasonPhrase, fields }

    /// Reads a strict status and ordered fields, validating before native creation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        let code = try container.decode(Int.self, forKey: .status)
        let reason = try container.decode(String.self, forKey: .reasonPhrase)
        guard (0...999).contains(code), HTTPField.isValidValue(reason) else { throw HTTPMessageError.invalidHead }
        let status = HTTPResponse.Status(code: code, reasonPhrase: reason)
        guard status.reasonPhrase == reason else { throw HTTPMessageError.invalidHead }
        head = try HTTPResponse(
            status: status,
            headerFields: HTTPFields(container.decode([FieldPayload].self, forKey: .fields)
                .map { try $0.field() }))
    }

    /// Writes Diorama's status, reason phrase, and literal field representation.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(head.status.code, forKey: .status)
        try container.encode(head.status.reasonPhrase, forKey: .reasonPhrase)
        try container.encode(head.headerFields.map(FieldPayload.init), forKey: .fields)
    }
}

extension HTTPRequestBody: Codable {
    /// Reads only complete request body cases; unavailable is rejected.
    public init(from decoder: any Decoder) throws {
        switch try BodyPayload(from: decoder).body(resources: ScenarioResourceCoding.resolutionContext(from: decoder)) {
        case .absent: self = .absent
        case let .bytes(bytes): self = .bytes(bytes)
        case let .resource(resource): self = .resource(resource)
        case .unavailable: throw HTTPMessageError.invalidBody
        }
    }

    /// Writes one explicit body case.
    public func encode(to encoder: any Encoder) throws {
        let body: HTTPResponseBody = switch self {
        case .absent: .absent
        case let .bytes(bytes): .bytes(bytes)
        case let .resource(resource): .resource(resource)
        }
        try body.encode(to: encoder)
    }
}

extension HTTPResponseBody: Codable {
    /// Reads a single validated response content interpretation.
    public init(from decoder: any Decoder) throws {
        self = try BodyPayload(from: decoder).body(resources: ScenarioResourceCoding.resolutionContext(from: decoder))
    }

    /// Writes one explicit response content case.
    public func encode(to encoder: any Encoder) throws {
        if case let .resource(resource) = self {
            try ScenarioResourceCoding.encode(ValuePreparation<[UInt8]>().admitPrepared(resource.bytes()),
                                              at: ScenarioResourcePath(resource.path), to: encoder)
        }
        try BodyPayload(self).encode(to: encoder)
    }
}

private enum BodyPayload: Codable {
    case absent
    case bytes([UInt8])
    case resource(ScenarioResourcePath)
    case unavailable

    enum CodingKeys: String, CodingKey, CaseIterable { case kind, text, base64, resource }
    private enum Kind: String, Codable { case absent, bytes, resource, unavailable }

    init(_ body: HTTPResponseBody) throws {
        switch body {
        case .absent: self = .absent
        case let .bytes(value): self = .bytes(value)
        case let .resource(value): self = try .resource(ScenarioResourcePath(value.path))
        case .unavailable: self = .unavailable
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .kind)
        let text = try container.contains(.text) ? container.decode(String.self, forKey: .text) : nil
        let base64 = try container.contains(.base64) ? container.decode(String.self, forKey: .base64) : nil
        let resource = try container.contains(.resource) ? container.decode(String.self, forKey: .resource) : nil
        guard let kind = Kind(rawValue: tag) else { throw HTTPMessageError.invalidBody }
        switch (kind, text, base64, resource) {
        case (.absent, nil, nil, nil): self = .absent
        case let (.bytes, text?, nil, nil): self = .bytes(Array(text.utf8))
        case let (.bytes, nil, encoded?, nil):
            if let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded {
                self = .bytes(Array(data))
            } else {
                throw HTTPMessageError.invalidBody
            }
        case let (.resource, nil, nil, path?):
            do { self = try .resource(ScenarioResourcePath(path)) } catch { throw HTTPMessageError.invalidResource }
        case (.unavailable, nil, nil, nil): self = .unavailable
        default: throw HTTPMessageError.invalidBody
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absent:
            try container.encode(Kind.absent, forKey: .kind)
        case let .bytes(value):
            try container.encode(Kind.bytes, forKey: .kind)
            if let string = String(validating: value, as: UTF8.self), Array(string.utf8) == value {
                try container.encode(string, forKey: .text)
            } else {
                try container.encode(Data(value).base64EncodedString(), forKey: .base64)
            }
        case let .resource(path):
            try container.encode(Kind.resource, forKey: .kind)
            try container.encode(path.value, forKey: .resource)
        case .unavailable:
            try container.encode(Kind.unavailable, forKey: .kind)
        }
    }

    func body(resources: ScenarioDocumentSnapshot?) throws -> HTTPResponseBody {
        switch self {
        case .absent: return .absent
        case let .bytes(value): return .bytes(value)
        case let .resource(path):
            guard let resources else { throw ScenarioResourceError.unavailable }
            let data = try resources.resource(at: path)
            return try .resource(HTTPBodyResource(
                path: path, bytes: ValuePreparation<[UInt8]>().admitPrepared(Array(data))))
        case .unavailable: return .unavailable
        }
    }
}
