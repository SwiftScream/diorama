import DioramaCore
import DioramaPersistence

/// One nonnegative successive delay, in milliseconds, with optional authorship.
public struct HTTPDelay: Equatable, Sendable, Codable {
    /// The sole effective delay and whether it is an authored playback override.
    public let milliseconds: OverridableValue<Int64>

    /// Validates the effective delay without accepting negative durations.
    public init(milliseconds: OverridableValue<Int64>) throws {
        guard milliseconds.value >= 0 else { throw HTTPLifecycleError.negativeDelay }
        self.milliseconds = milliseconds
    }

    /// Reads the shared duration grammar and observed/override editing form.
    public init(from decoder: any Decoder) throws {
        let text = try OverridableValue<String>(from: decoder)
        guard let value = StableTimeCodec.parseDuration(text.value), value >= 0 else {
            throw try DecodingError.dataCorruptedError(
                in: decoder.singleValueContainer(), debugDescription: "Expected a nonnegative HTTP delay")
        }
        try self.init(milliseconds: text.map { _ in value })
    }

    /// Writes a canonical scalar or the sole effective override.
    public func encode(to encoder: any Encoder) throws {
        try milliseconds.map(StableTimeCodec.formatDuration).encode(to: encoder)
    }

    static func add(_ elapsed: Int64, _ delay: Int64) throws -> Int64 {
        let sum = elapsed.addingReportingOverflow(delay)
        guard !sum.overflow else { throw HTTPLifecycleError.delayOverflow }
        return sum.partialValue
    }
}

/// A value delivered after one local delay, independent of global chronology.
public struct HTTPTimed<Value: Sendable>: Sendable {
    /// Delay from the preceding lifecycle event or invocation.
    public let after: HTTPDelay
    /// The value introduced at this lifecycle node.
    public let value: Value

    /// Builds a timed value from an already validated delay.
    public init(after: HTTPDelay, value: Value) {
        self.after = after
        self.value = value
    }
}

extension HTTPTimed: Equatable where Value: Equatable {}

extension HTTPTimed: Codable where Value: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case after, value }

    /// Reads one explicit delay and value, rejecting additional fields.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        try self.init(after: fields.decode(HTTPDelay.self, forKey: .after),
                      value: fields.decode(Value.self, forKey: .value))
    }

    /// Writes the Diorama-owned timed-value shape.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(after, forKey: .after)
        try fields.encode(value, forKey: .value)
    }
}
