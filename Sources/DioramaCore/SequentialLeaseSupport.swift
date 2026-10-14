import Synchronization

/// A sequential-track lease for a track without a header.
public typealias HeaderlessSequentialTrackLease<Value: Sendable> = SequentialTrackLease<Value, Void>

/// A small shared closure bit, never a reference back to execution resources.
final class ExecutionAdmission: Sendable {
    private struct State { var closed = false; var published = false }
    private let state = Mutex(State())
    var isClosed: Bool {
        state.withLock { $0.closed }
    }

    var isPublished: Bool {
        state.withLock { $0.published && !$0.closed }
    }

    func publish() {
        state.withLock { $0.published = true }
    }

    func close() {
        state.withLock { $0.closed = true }
    }
}

protocol AnySequentialLease: Sendable {
    var id: TrackID { get }
    func join() async
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
