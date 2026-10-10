/// Prepared content and its lease share the same value and header types.
protocol PreparedTrackEntry<Value, Header>: Sendable {
    associatedtype Value: Sendable
    associatedtype Header: Sendable

    var lease: SequentialTrackLease<Value, Header> { get }
    var content: SequentialTrack<Value, Header> { get }
}

struct PreparedTrack<Value: Sendable, Header: Sendable>: PreparedTrackEntry {
    let lease: SequentialTrackLease<Value, Header>
    let content: SequentialTrack<Value, Header>
}
