import DioramaCore
import Foundation

private enum WallPreparationError: Error {
    case invalidObservation
}

/// Recording-only state, accessed under the live source's serialization lock.
struct WallRecordingState: Sendable {
    private struct Progress: Sendable {
        let origin: Date
        let previous: Date
        let cumulative: Int64
        let offsetMinutes: Int
    }

    private let timeZone: TimeZone
    private var progress: Progress?

    /// Capture the current zone at activation, before the source factory runs.
    /// The internal parameter supports deterministic timezone conformance tests.
    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    mutating func read(
        capturing capture: () -> Date,
        lease: SequentialTrackLease<OverridableValue<Date>, Int?>,
        lastReturned: inout Date?) -> Date?
    {
        var native: Date?
        var next: Progress?
        do {
            try lease.append(capturing: {
                let observed = capture()
                native = observed
                lastReturned = observed
                let prepared = try prepare(observed)
                if progress == nil {
                    try lease.setHeader(
                        capturing: { prepared.offsetMinutes }, preparation: ValuePreparation<Int?>())
                }
                next = prepared
                return .observed(prepared.previous)
            }, preparation: ValuePreparation<OverridableValue<Date>>())
        } catch {
            return native
        }
        guard let next else {
            preconditionFailure("Admitted wall observation must be representable")
        }
        progress = next
        return native
    }

    private func prepare(_ observed: Date) throws -> Progress {
        guard let rounded = StableTimeCodec.roundedToMillisecond(observed) else {
            throw WallPreparationError.invalidObservation
        }
        if let progress {
            guard let delta = WallRecording.delta(from: progress.previous, to: rounded) else {
                throw WallPreparationError.invalidObservation
            }
            let (cumulative, overflow) = progress.cumulative.addingReportingOverflow(delta)
            guard !overflow, WallRecording.shiftDate(progress.origin, by: cumulative) == rounded else {
                throw WallPreparationError.invalidObservation
            }
            return Progress(
                origin: progress.origin, previous: rounded, cumulative: cumulative,
                offsetMinutes: progress.offsetMinutes)
        }
        let seconds = timeZone.secondsFromGMT(for: observed)
        guard seconds.isMultiple(of: 60),
              WallOrigin(date: rounded, offsetMinutes: seconds / 60) != nil
        else { throw WallPreparationError.invalidObservation }
        return Progress(origin: rounded, previous: rounded, cumulative: 0, offsetMinutes: seconds / 60)
    }
}
