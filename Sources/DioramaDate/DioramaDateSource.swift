import DioramaCore
import Foundation
import Synchronization

/// A synchronous, nonthrowing source of civil time.
///
/// A date attachment accepts a source of this type and vends the same small
/// dependency to application code. Sources need not round their native dates.
public protocol DioramaDateSource: Sendable {
    /// The current native or replayed wall observation.
    var now: Date { get }
}

struct SystemWallDateSource: DioramaDateSource {
    var now: Date {
        Date()
    }
}

enum LiveWallMode: Sendable {
    case record(WallRecordingState)
    case passthrough
}

private enum WallReadResult {
    case value(Date)
    case unavailable
    case alreadyReported
}

/// The lock keeps one source read and its track operation in one atomic order.
/// Finish detaches the source so escaped handles cannot read it again.
final class LiveDateSource<Source: DioramaDateSource>: DioramaDateSource, Sendable {
    private struct State: Sendable {
        var source: Source?
        var lastReturned: Date?
        var mode: LiveWallMode
    }

    private let lease: SequentialTrackLease<OverridableValue<Date>, Int?>
    private let state: Mutex<State>

    init(mode: LiveWallMode, lease: SequentialTrackLease<OverridableValue<Date>, Int?>,
         source: Source)
    {
        self.lease = lease
        state = Mutex(State(source: source, mode: mode))
    }

    var now: Date {
        let result = state.withLock { state -> WallReadResult in
            guard !lease.isClosed, let source = state.source else { return .unavailable }
            switch state.mode {
            case var .record(recording):
                let native = recording.read(
                    capturing: { source.now }, lease: lease, lastReturned: &state.lastReturned)
                state.mode = .record(recording)
                return native.map(WallReadResult.value) ?? .alreadyReported
            case .passthrough:
                let native = source.now
                state.lastReturned = native
                return .value(native)
            }
        }
        switch result {
        case let .value(date):
            return date
        case .unavailable:
            _ = lease.report(.system(DiagnosticLabel("clock-wall-operation-after-close")))
        case .alreadyReported:
            break
        }
        return state.withLock { $0.lastReturned } ?? Date(timeIntervalSince1970: 0)
    }

    func close() {
        let detached = state.withLock { state in
            let source = state.source
            state.source = nil
            return source
        }
        withExtendedLifetime(detached) {}
    }
}

/// Replays effective dates; the lease owns atomic consumption and continuation.
final class ReplayDateSource: DioramaDateSource, Sendable {
    static let unixEpoch = Date(timeIntervalSince1970: 0)

    private let lease: SequentialTrackLease<OverridableValue<Date>, Int?>

    init(lease: SequentialTrackLease<OverridableValue<Date>, Int?>) {
        self.lease = lease
    }

    var now: Date {
        (try? lease.consumeNext().value) ?? Self.unixEpoch
    }
}
