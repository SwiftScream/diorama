import DioramaPersistence

/// One observed delivery's byte count and delay from the preceding event.
public struct HTTPBodySegment: Equatable, Sendable, Codable {
    /// Nonnegative observed byte count, used as a relative weight after body edits.
    public let byteWeight: Int64
    /// Successive delay from the response head or previous segment.
    public let after: HTTPDelay

    /// Builds a segment without retaining a competing copy of its bytes.
    public init(byteWeight: Int64, after: HTTPDelay) throws {
        guard byteWeight >= 0 else { throw HTTPLifecycleError.negativeByteWeight }
        self.byteWeight = byteWeight
        self.after = after
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case byteWeight, after }

    /// Reads a nonnegative integer weight and one validated effective delay.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        let weight = try fields.decode(Int64.self, forKey: .byteWeight)
        guard weight >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .byteWeight, in: fields, debugDescription: "Expected a nonnegative HTTP byte weight")
        }
        try self.init(byteWeight: weight, after: fields.decode(HTTPDelay.self, forKey: .after))
    }

    /// Writes only the weight and successive delay, never segment bytes.
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(byteWeight, forKey: .byteWeight)
        try fields.encode(after, forKey: .after)
    }
}

/// A nonempty sequence of weighted deliveries with checked weight and delay sums.
public struct HTTPBodyProfile: Equatable, Sendable, Codable {
    /// Stable delivery order; zero-byte deliveries retain their timing position.
    public let segments: [HTTPBodySegment]
    /// Sum of original weights; it need not equal the current body's byte count.
    public let totalByteWeight: Int64
    /// Elapsed milliseconds from the head through the final segment.
    public let durationMilliseconds: Int64

    /// Validates a nonempty profile and Int64-bounded cumulative scalar values.
    public init(segments: [HTTPBodySegment]) throws {
        guard !segments.isEmpty else { throw HTTPLifecycleError.emptyBodyProfile }
        var weight: Int64 = 0
        var elapsed: Int64 = 0
        for segment in segments {
            let sum = weight.addingReportingOverflow(segment.byteWeight)
            guard !sum.overflow else { throw HTTPLifecycleError.byteWeightOverflow }
            weight = sum.partialValue
            elapsed = try HTTPDelay.add(elapsed, segment.after.milliseconds.value)
        }
        self.segments = segments
        totalByteWeight = weight
        durationMilliseconds = elapsed
    }

    /// Allocates contiguous byte ranges over the current inline or resolved resource length.
    ///
    /// Cumulative boundaries round down using exact integer arithmetic. The final
    /// segment ends at `byteCount`, including when all original weights are zero.
    /// Empty allocations retain their segment and delay; no text decoding occurs.
    public func allocate(byteCount: Int) throws -> [HTTPBodyAllocation] {
        guard byteCount >= 0 else { throw HTTPLifecycleError.negativeBodyLength }
        var weight: Int64 = 0
        var elapsed: Int64 = 0
        var lower = 0
        return segments.enumerated().map { index, segment in
            // Profile construction proves these sums fit. Int128 multiplication
            // holds the product of any supported Int byte count and Int64 weight.
            weight += segment.byteWeight
            elapsed += segment.after.milliseconds.value
            let upper: Int = if index == segments.count - 1 {
                byteCount
            } else if totalByteWeight == 0 {
                0
            } else {
                Int(Int128(byteCount) * Int128(weight) / Int128(totalByteWeight))
            }
            defer { lower = upper }
            return HTTPBodyAllocation(byteRange: lower..<upper, after: segment.after, offsetMilliseconds: elapsed)
        }
    }

    /// Reads a segment array, validating cumulative values before constructing a profile.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let segments = try container.decode([HTTPBodySegment].self)
        do {
            try self.init(segments: segments)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected a nonempty HTTP profile with bounded weight and delay sums")
        }
    }

    /// Writes the original weights and delays, without derived ranges or totals.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(segments)
    }
}

/// One effective delivery, derived from a validated profile and current body length.
public struct HTTPBodyAllocation: Equatable, Sendable {
    /// Contiguous range into the single authoritative body; may be empty.
    public let byteRange: Range<Int>
    /// Original effective successive delay, including override authorship.
    public let after: HTTPDelay
    /// Cumulative effective milliseconds from the response head to this delivery.
    public let offsetMilliseconds: Int64
}
