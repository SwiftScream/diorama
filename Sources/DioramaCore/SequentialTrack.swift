/// One value and its stable identity in a sequential track.
public struct SequentialRecord<Value: Sendable>: Sendable {
    /// The complete stable identity of this record.
    public let identity: RecordIdentity

    /// The system-defined stable value.
    public let value: Value
}

/// Immutable, typed in-memory content ordered within one track.
///
/// Values only need to be sendable. In-memory tracks do not require `Codable`.
public struct SequentialTrack<Value: Sendable>: Sendable {
    /// The stable identity of this track.
    public let id: TrackID

    /// Records in deterministic sequence order.
    public let records: [SequentialRecord<Value>]

    /// Creates typed sequential content.
    ///
    /// Record identities are assigned monotonically from zero in the order of
    /// `values`. An empty values array is valid content.
    ///
    /// - Parameters:
    ///   - id: The stable track identity.
    ///   - values: Stable values in their deterministic track order.
    public init(id: TrackID, values: [Value] = []) {
        self.id = id
        records = values.enumerated().map { offset, value in
            SequentialRecord(
                identity: RecordIdentity(
                    trackID: id,
                    sequence: UInt64(offset)),
                value: value)
        }
    }
}

extension SequentialRecord: Equatable where Value: Equatable {}

extension SequentialTrack: Equatable where Value: Equatable {}
