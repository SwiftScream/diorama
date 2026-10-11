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

struct DateRecordState<Source: DioramaDateSource>: Sendable {
    let source: Source
    let values: SequentialTrackLease<OverridableValue<Date>, Int?>
    var recording: WallRecordingState
    var lastReturned = Date(timeIntervalSince1970: 0)
}

struct DateReplayState: Sendable {
    let values: SequentialTrackLease<OverridableValue<Date>, Int?>
    var lastReturned = Date(timeIntervalSince1970: 0)
}

struct RecordingDateSource<Source: DioramaDateSource>: DioramaDateSource {
    let runtime: SystemRuntime<DateRecordState<Source>>
    let last: SystemSnapshot<Date>

    var now: Date {
        do {
            return try runtime.withActiveState { state, operation in
                let source = state.source
                _ = state.recording.read(capturing: { source.now }, lease: state.values,
                                         lastReturned: &state.lastReturned, operation: &operation)
                return state.lastReturned
            }
        } catch {
            return last.value
        }
    }
}

struct ReplayingDateSource: DioramaDateSource {
    let runtime: SystemRuntime<DateReplayState>
    let last: SystemSnapshot<Date>

    var now: Date {
        do {
            return try runtime.withActiveState { state, operation in
                if let value = try? operation.consumeNext(on: state.values) {
                    state.lastReturned = value.value
                }
                return state.lastReturned
            }
        } catch {
            return last.value
        }
    }
}
