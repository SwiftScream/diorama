import Foundation

/// A normalized millisecond timestamp and its fixed numeric display offset.
package struct TimestampOrigin: Equatable, Sendable {
    package let date: Date
    /// Whole minutes east of UTC, retained for canonical ISO 8601 output.
    package let offsetMinutes: Int

    /// Normalizes the instant and validates the portable date and offset ranges.
    package init?(date: Date, offsetMinutes: Int) {
        guard let rounded = StableTimeCodec.roundedToMillisecond(date),
              StableTimeCodec.formatOrigin(rounded, offsetMinutes: offsetMinutes) != nil
        else { return nil }
        self.date = rounded
        self.offsetMinutes = offsetMinutes
    }

    package init?(_ text: String) {
        guard let parsed = StableTimeCodec.parseOrigin(text) else { return nil }
        self.init(date: parsed.date, offsetMinutes: parsed.offsetMinutes)
    }

    /// Formats the admitted value without further normalization.
    package var text: String {
        // Construction proves the normalized instant and offset are representable.
        StableTimeCodec.formatOrigin(date, offsetMinutes: offsetMinutes)!
    }

    /// Adds a signed logical offset, rejecting dates outside the portable range.
    package func advanced(by milliseconds: Int64) -> Date? {
        let seconds = date.timeIntervalSince1970 + Double(milliseconds) / 1000
        guard seconds.isFinite else { return nil }
        return StableTimeCodec.roundedToMillisecond(Date(timeIntervalSince1970: seconds))
    }
}
