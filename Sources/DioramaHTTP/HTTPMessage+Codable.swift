import DioramaCore
import DioramaPersistence
import Foundation
import HTTPTypes

/// These representations belong to Diorama, independently of HTTPTypes.Codable.
struct FieldPayload: Codable {
    let name: HTTPField.Name
    let value: Value

    enum Value: Codable {
        case literal([UInt8])
        case bodyByteCount

        private enum Keys: String, CodingKey, CaseIterable { case derivedFrom }

        init(from decoder: any Decoder) throws {
            let field = try decoder.singleValueContainer()
            if let literal = try? field.decode(String.self) {
                let bytes = literal.unicodeScalars.compactMap { UInt8(exactly: $0.value) }
                guard bytes.count == literal.unicodeScalars.count, HTTPField.isValidValue(bytes) else {
                    throw DecodingError.dataCorruptedError(in: field, debugDescription: "Invalid HTTP field value")
                }
                self = .literal(bytes)
            } else {
                let fields = try decoder.strictContainer(keyedBy: Keys.self)
                guard try fields.decode(String.self, forKey: .derivedFrom) == "bodyByteCount" else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .derivedFrom, in: fields, debugDescription: "Unknown HTTP field derivation")
                }
                self = .bodyByteCount
            }
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case let .literal(bytes):
                var field = encoder.singleValueContainer()
                try field.encode(String(String.UnicodeScalarView(bytes.map { UnicodeScalar($0) })))
            case .bodyByteCount:
                var fields = encoder.container(keyedBy: Keys.self)
                try fields.encode("bodyByteCount", forKey: .derivedFrom)
            }
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case name, value }

    init(_ field: HTTPField, derived: Bool = false) {
        name = field.name
        if derived, field.name == .contentLength {
            value = .bodyByteCount
        } else {
            value = .literal(field.withUnsafeBytesOfValue { Array($0) })
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        guard let name = try HTTPField.Name(container.decode(String.self, forKey: .name)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container, debugDescription: "Invalid HTTP field name")
        }
        self.name = name
        value = try container.decode(Value.self, forKey: .value)
        if case .bodyByteCount = value, name != .contentLength {
            throw DecodingError.dataCorruptedError(
                forKey: .value, in: container, debugDescription: "Only Content-Length can derive from the body")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(name.rawName, forKey: .name)
        try fields.encode(value, forKey: .value)
    }

    static func decode<Key>(from container: KeyedDecodingContainer<Key>, key: Key, byteCount: Int? = nil) throws
        -> (HTTPFields, derivesLength: Bool)
    {
        let payloads = try container.decode([Self].self, forKey: key)
        let derivesLength = payloads.contains {
            if case .bodyByteCount = $0.value {
                true
            } else {
                false
            }
        }
        if derivesLength, payloads.filter({ $0.name == .contentLength }).count != 1 {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "Derived Content-Length requires a single length field")
        }
        let fields = try payloads.map { payload -> HTTPField in
            switch payload.value {
            case let .literal(bytes):
                return HTTPField(name: payload.name, value: bytes)
            case .bodyByteCount:
                guard let byteCount else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key, in: container, debugDescription: "Derived Content-Length requires a complete body")
                }
                return HTTPField(name: payload.name, value: String(byteCount))
            }
        }
        return (HTTPFields(fields), derivesLength)
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
            throw DecodingError.dataCorruptedError(forKey: .method, in: container, debugDescription: "Invalid method")
        }
        func target(_ key: CodingKeys) throws -> String? {
            guard container.contains(key) else { return nil }
            let value = try container.decode(String.self, forKey: key)
            guard HTTPField.isValidValue(value) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Invalid target")
            }
            return value
        }
        let body = try container.decode(HTTPRequestBody.self, forKey: .body)
        let (fields, derivesContentLength) = try FieldPayload.decode(from: container, key: .fields,
                                                                     byteCount: body.byteCount)
        let head = try HTTPRequest(method: method, scheme: target(.scheme), authority: target(.authority),
                                   path: target(.path), headerFields: fields)
        if derivesContentLength {
            guard HTTPContentLength.unambiguous(method: head.method),
                  HTTPContentLength.unambiguous(fields: head.headerFields)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .fields, in: container, debugDescription: "Invalid derived request length")
            }
        }
        try self.init(head: head, body: body, derivesContentLength: derivesContentLength)
    }

    /// Writes explicit method/target/field/body keys, never dependency Codable.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(head.method.rawValue, forKey: .method)
        try container.encodeIfPresent(head.scheme, forKey: .scheme)
        try container.encodeIfPresent(head.authority, forKey: .authority)
        try container.encodeIfPresent(head.path, forKey: .path)
        try container.encode(head.headerFields.map { FieldPayload($0, derived: derivesContentLength) }, forKey: .fields)
        try container.encode(body, forKey: .body)
    }
}

extension HTTPResponseHead: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case status, reasonPhrase, fields }

    /// Reads a strict status and ordered fields, validating before native creation.
    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, byteCount: nil)
    }

    init(from decoder: any Decoder, byteCount: Int?) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        let code = try container.decode(Int.self, forKey: .status)
        let reason = try container.decode(String.self, forKey: .reasonPhrase)
        guard (0...999).contains(code) else {
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Invalid status")
        }
        let status = HTTPResponse.Status(code: code, reasonPhrase: reason)
        guard HTTPField.isValidValue(reason), status.reasonPhrase == reason else {
            throw DecodingError.dataCorruptedError(
                forKey: .reasonPhrase, in: container, debugDescription: "Invalid reason phrase")
        }
        let (fields, derivesContentLength) = try FieldPayload.decode(
            from: container, key: .fields, byteCount: byteCount)
        self.init(head: HTTPResponse(status: status, headerFields: fields), derivesContentLength: derivesContentLength)
    }

    /// Writes Diorama's status, reason phrase, and literal field representation.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(head.status.code, forKey: .status)
        try container.encode(head.status.reasonPhrase, forKey: .reasonPhrase)
        try container.encode(head.headerFields.map { FieldPayload($0, derived: derivesContentLength) }, forKey: .fields)
    }
}

extension HTTPRequestBody: Codable {
    /// Reads only complete request body cases; unavailable is rejected.
    public init(from decoder: any Decoder) throws {
        switch try BodyPayload(from: decoder).body(resources: ScenarioResourceCoding.resolutionContext(from: decoder)) {
        case .absent: self = .absent
        case let .bytes(bytes): self = .bytes(bytes)
        case let .resource(resource): self = .resource(resource)
        case .unavailable:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [BodyPayload.CodingKeys.kind],
                                                    debugDescription: "Request body cannot be unavailable"))
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
        guard let kind = Kind(rawValue: tag) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown body kind")
        }
        switch (kind, text, base64, resource) {
        case (.absent, nil, nil, nil): self = .absent
        case let (.bytes, text?, nil, nil): self = .bytes(Array(text.utf8))
        case let (.bytes, nil, encoded?, nil):
            guard let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded else {
                throw DecodingError.dataCorruptedError(
                    forKey: .base64, in: container, debugDescription: "Invalid base64 body")
            }
            self = .bytes(Array(data))
        case let (.resource, nil, nil, path?):
            do {
                self = try .resource(ScenarioResourcePath(path))
            } catch ScenarioResourceError.invalidPath {
                throw DecodingError.dataCorruptedError(
                    forKey: .resource, in: container, debugDescription: "Invalid body resource path")
            }
        case (.unavailable, nil, nil, nil): self = .unavailable
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Body fields do not match the body kind"))
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
