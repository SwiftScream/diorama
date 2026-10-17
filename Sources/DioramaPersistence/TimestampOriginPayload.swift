import DioramaCore

/// The shared ISO 8601 scalar representation of a normalized timestamp origin.
package struct TimestampOriginPayload: Codable, Sendable {
    package let value: TimestampOrigin

    package init(_ value: TimestampOrigin) {
        self.value = value
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = TimestampOrigin(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp origin")
        }
        self.value = value
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value.text)
    }
}
