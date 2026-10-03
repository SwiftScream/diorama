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
/// A typed header belongs to the track, outside its record sequence. Use
/// `Void` as the header type for a track without one.
public struct SequentialTrack<Value: Sendable, Header: Sendable>: Sendable {
    /// The stable identity of this track.
    public let id: TrackID

    /// Records in deterministic sequence order.
    public let records: [SequentialRecord<Value>]

    /// The prepared header, including when this track has no records.
    /// Headerless tracks use the unit value `()` of `Void`.
    public let header: Header

    /// Creates typed sequential content with a required header.
    ///
    /// Record identities are assigned monotonically from zero in the order of
    /// `values`. An empty values array is valid content.
    ///
    /// - Parameters:
    ///   - id: The stable track identity.
    ///   - header: A value produced by the system's preparation policy, or the
    ///     unit marker for a headerless track.
    ///   - values: Values produced by a system's preparation policy, in their
    ///     deterministic track order. Raw capture-local values cannot be added.
    public init(id: TrackID, header: PreparedValue<Header>, values: [PreparedValue<Value>] = []) {
        self.id = id
        self.header = header.value
        records = values.enumerated().map { offset, value in
            SequentialRecord(
                identity: RecordIdentity(trackID: id, sequence: UInt64(offset)),
                value: value.value)
        }
    }

    init(id: TrackID, header: Header,
         preparedRecords: [SequentialRecord<Value>])
    {
        self.id = id
        self.header = header
        records = preparedRecords
    }

    func removingRecords() -> Self {
        Self(id: id, header: header, preparedRecords: [])
    }
}

/// A sequential track whose header is the unit value `()`.
public typealias HeaderlessSequentialTrack<Value: Sendable> = SequentialTrack<Value, Void>

public extension SequentialTrack where Header == Void {
    /// Creates a track without a header. Its record sequence may be empty.
    init(id: TrackID, values: [PreparedValue<Value>] = []) {
        self.init(id: id, header: .init(), values: values)
    }
}

extension SequentialRecord: Equatable where Value: Equatable {}
