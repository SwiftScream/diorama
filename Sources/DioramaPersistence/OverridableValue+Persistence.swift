import DioramaCore

private enum OverridableValueCodingKeys: String, CodingKey, CaseIterable {
    case observed
    case override
}

/// The shared persisted form for fields that allow authored overrides.
///
/// Top-level `observed` and `override` keys are reserved for this form.
/// Systems whose raw values use those keys need their own field schema.
extension OverridableValue: Codable where Value: Codable {
    /// Reads the shared observed/override editing form into one effective value.
    public init(from decoder: any Decoder) throws {
        if let tagged = try? decoder.container(keyedBy: OverridableValueCodingKeys.self),
           tagged.contains(.observed) || tagged.contains(.override)
        {
            self = try Self.decodeTagged(from: decoder)
        } else if let value = try? Value(from: decoder) {
            self = .observed(value)
        } else {
            self = try Self.decodeTagged(from: decoder)
        }
    }

    /// Writes the effective observation directly or an explicit override tag.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .observed(value):
            try value.encode(to: encoder)
        case let .override(value):
            var container = encoder.container(keyedBy: OverridableValueCodingKeys.self)
            try container.encode(value, forKey: .override)
        }
    }

    private static func decodeTagged(from decoder: any Decoder) throws -> Self {
        let container = try decoder.strictContainer(keyedBy: OverridableValueCodingKeys.self)
        let observed = try container.contains(.observed)
            ? container.decode(Value.self, forKey: .observed) : nil
        let override = try container.contains(.override)
            ? container.decode(Value.self, forKey: .override) : nil
        if let override {
            return .override(override)
        } else if let observed {
            return .observed(observed)
        } else {
            throw try DecodingError.dataCorruptedError(
                in: decoder.singleValueContainer(),
                debugDescription: "Field requires observed or override")
        }
    }
}
