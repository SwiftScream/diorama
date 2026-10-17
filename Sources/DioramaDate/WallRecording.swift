import DioramaCore
import Foundation

/// Safe structural failures for recorded wall observations.
enum WallRecordingError: Error, Equatable, Sendable {
    /// Observations require an origin.
    case missingOrigin
    /// An empty recording cannot retain an origin.
    case originWithoutObservations
    /// Position zero must be the origin's zero delta.
    case nonzeroFirstObservation
    /// Adding effective successive deltas would overflow `Int64`.
    case cumulativeOverflow(position: Int)
    /// A wall value is outside the portable range or loses millisecond meaning.
    case unrepresentableWallValue(position: Int)
    /// A track has an unexpected identity, type, or value order.
    case invalidTrackLayout
}

/// Strict semantic wall content for one date attachment.
///
/// Empty content has neither an origin nor observations. Nonempty content has
/// a position-zero `0ms` observation followed by signed successive deltas.
/// There are no replay delays in this model.
struct WallRecording: Equatable, Sendable {
    /// The first effective wall value, absent only for an empty recording.
    let origin: OverridableValue<TimestampOrigin>?
    /// Effective successive deltas in deterministic read order.
    let observations: [OverridableValue<Int64>]
    /// Effective absolute values in the same order as `observations`.
    let effectiveDates: [Date]

    /// Absolute wall values and their positional authored state for the track.
    var effectiveValues: [OverridableValue<Date>] {
        effectiveDates.enumerated().map { position, date in
            let overridden = position == 0 ? origin?.isOverride == true : observations[position].isOverride
            return overridden ? .override(date) : .observed(date)
        }
    }

    var offsetMinutes: Int? {
        origin?.value.offsetMinutes
    }

    /// A declared date attachment with no wall reads.
    static let empty = WallRecording(validatedOrigin: nil, observations: [], effectiveDates: [])

    /// Validates and normalizes programmatically authored wall content.
    ///
    /// A position-zero override shifts the origin and becomes an ordinary
    /// `0ms` entry. Later deltas keep their positions and authorship.
    init(
        origin: OverridableValue<TimestampOrigin>?,
        observations: [OverridableValue<Int64>]) throws(WallRecordingError)
    {
        guard !observations.isEmpty else {
            guard origin == nil else { throw .originWithoutObservations }
            self = .empty
            return
        }
        guard var origin else { throw .missingOrigin }

        let first = observations[0]
        if first.isOverride {
            guard let shiftedDate = origin.value.advanced(by: first.value),
                  let shifted = TimestampOrigin(
                      date: shiftedDate, offsetMinutes: origin.value.offsetMinutes)
            else {
                throw .unrepresentableWallValue(position: 0)
            }
            origin = .override(shifted)
        } else if first.value != 0 {
            throw .nonzeroFirstObservation
        }

        var cumulative: Int64 = 0
        var cumulativeDeltas: [Int64] = [0]
        for position in observations.indices.dropFirst() {
            let (next, overflow) = cumulative.addingReportingOverflow(observations[position].value)
            guard !overflow else { throw .cumulativeOverflow(position: position) }
            cumulative = next
            cumulativeDeltas.append(next)
        }

        let dates = try Self.validatedDates(
            origin: origin.value, observations: observations, cumulativeDeltas: cumulativeDeltas)

        self.init(
            validatedOrigin: origin,
            observations: [.observed(0)] + observations.dropFirst(),
            effectiveDates: dates)
    }

    /// Reconstructs the schema view from one validated absolute-date track.
    init(offsetMinutes: Int?, values: [OverridableValue<Date>]) throws(WallRecordingError) {
        guard let first = values.first else {
            guard offsetMinutes == nil else { throw .originWithoutObservations }
            self = .empty
            return
        }
        guard let offsetMinutes else { throw .missingOrigin }
        guard let origin = TimestampOrigin(date: first.value, offsetMinutes: offsetMinutes),
              origin.date == first.value
        else { throw .unrepresentableWallValue(position: 0) }

        var deltas: [OverridableValue<Int64>] = [.observed(0)]
        for position in values.indices.dropFirst() {
            let date = values[position].value
            guard StableTimeCodec.roundedToMillisecond(date) == date else {
                throw .unrepresentableWallValue(position: position)
            }
            guard let delta = Self.delta(from: values[position - 1].value, to: date) else {
                throw .unrepresentableWallValue(position: position)
            }
            deltas.append(values[position].isOverride ? .override(delta) : .observed(delta))
        }
        self = try WallRecording(
            origin: first.isOverride ? .override(origin) : .observed(origin),
            observations: deltas)
        for position in values.indices where effectiveDates[position] != values[position].value {
            throw .unrepresentableWallValue(position: position)
        }
    }

    private init(
        validatedOrigin: OverridableValue<TimestampOrigin>?,
        observations: [OverridableValue<Int64>],
        effectiveDates: [Date])
    {
        origin = validatedOrigin
        self.observations = observations
        self.effectiveDates = effectiveDates
    }

    private static func validatedDates(
        origin: TimestampOrigin, observations: [OverridableValue<Int64>], cumulativeDeltas: [Int64])
        throws(WallRecordingError) -> [Date]
    {
        var dates = [origin.date]
        for position in observations.indices.dropFirst() {
            guard let date = origin.advanced(by: cumulativeDeltas[position]),
                  delta(from: dates[position - 1], to: date) == observations[position].value
            else { throw .unrepresentableWallValue(position: position) }
            dates.append(date)
        }
        return dates
    }

    static func delta(from earlier: Date, to later: Date) -> Int64? {
        let milliseconds = ((later.timeIntervalSince1970 - earlier.timeIntervalSince1970) * 1000).rounded()
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max)
        else { return nil }
        return Int64(exactly: milliseconds)
    }
}
