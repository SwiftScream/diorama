import DioramaCore
import Foundation

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

struct DateRecordState: Sendable {
    let values: SequentialTrackLease<OverridableValue<Date>, Int?>
    var recording: WallRecordingState
}

struct RecordingDateSource<Source: DioramaDateSource>: DioramaDateSource {
    let execution: SystemExecution<DateRecordState>
    let source: Source

    var now: Date {
        do {
            return try execution.state.withLock { state, operation in
                state.recording.read(capturing: { source.now }, lease: state.values,
                                     operation: &operation) ?? source.now
            }
        } catch {
            return source.now
        }
    }
}

struct ReplayingDateSource: DioramaDateSource {
    static let unixEpoch = Date(timeIntervalSince1970: 0)
    let values: SequentialTrackLease<OverridableValue<Date>, Int?>

    var now: Date {
        (try? values.consumeNext().value) ?? Self.unixEpoch
    }
}
