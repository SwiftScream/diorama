import Synchronization

/// A sequential-track lease for a track without a header.
public typealias HeaderlessSequentialTrackLease<Value: Sendable> = SequentialTrackLease<Value, Void>

/// A small shared closure bit, never a reference back to execution resources.
final class ExecutionAdmission: Sendable {
    private let closed = Mutex(false)
    var isClosed: Bool {
        closed.withLock { $0 }
    }

    func close() {
        closed.withLock { $0 = true }
    }
}

protocol AnySequentialLease: Sendable {
    var id: TrackID { get }
    @discardableResult
    func close(mergingRecording: Bool) -> ClosedSequentialTrack
}

struct ClosedSequentialTrack: Sendable {
    let usage: SequentialTrackUsage
    let recording: (any AnySequentialTrack)?
}

/// Safe evidence for a failed typed sequential-track operation.
public struct SequentialOperationFailure: Error, Equatable, Sendable {
    /// The diagnostic retained before this failure was returned.
    public let diagnostic: Diagnostic
}
