import Foundation

/// Shared, locale-independent millisecond and wall-origin scalars.
///
/// These codecs do not decide whether a signed value is valid for a particular
/// field. System readers validate elapsed durations and wall deltas separately.
public enum StableTimeCodec {
    private static let maximumPortableOffsetMinutes = 14 * 60

    /// Reads signed integral milliseconds or seconds with up to three decimals.
    ///
    /// A leading `+` or `-` is allowed. Whitespace, exponent notation, empty
    /// digits, and precision finer than one millisecond are rejected.
    public static func parseDuration(_ text: String) -> Int64? {
        if text.hasSuffix("ms") {
            let number = text.dropLast(2)
            guard isSignedASCIIInteger(number) else { return nil }
            return Int64(number)
        }
        if text.hasSuffix("s") {
            return parseSeconds(text.dropLast())
        }
        return nil
    }

    private static func parseSeconds(_ number: Substring) -> Int64? {
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), isSignedASCIIInteger(parts[0]),
              let wholeSeconds = Int64(parts[0])
        else { return nil }

        let fractionalMilliseconds: Int64
        if parts.count == 2 {
            let digits = parts[1].utf8
            guard (1...3).contains(digits.count), digits.allSatisfy(\.isASCIIDigit),
                  let fraction = Int64(parts[1])
            else { return nil }
            let scale: Int64 = switch digits.count {
            case 1: 100
            case 2: 10
            default: 1
            }
            fractionalMilliseconds = fraction * scale
        } else {
            fractionalMilliseconds = 0
        }

        let (wholeMilliseconds, multiplicationOverflow) = wholeSeconds.multipliedReportingOverflow(by: 1000)
        guard !multiplicationOverflow else { return nil }
        let signedFraction = number.utf8.first == .minusSign ? -fractionalMilliseconds : fractionalMilliseconds
        let (result, additionOverflow) = wholeMilliseconds.addingReportingOverflow(signedFraction)
        return additionOverflow ? nil : result
    }

    private static func isSignedASCIIInteger(_ text: Substring) -> Bool {
        let units = text.utf8
        let hasSign = units.first == .plusSign || units.first == .minusSign
        let digits = units.dropFirst(hasSign ? 1 : 0)
        return !digits.isEmpty && digits.allSatisfy(\.isASCIIDigit)
    }

    /// Writes the one canonical representation of a millisecond duration.
    public static func formatDuration(_ milliseconds: Int64) -> String {
        guard milliseconds != 0 else { return "0ms" }
        let sign = milliseconds < 0 ? "-" : ""
        let magnitude = milliseconds.magnitude
        if magnitude.isMultiple(of: 1000) {
            return "\(sign)\(magnitude / 1000)s"
        }
        return "\(sign)\(magnitude)ms"
    }

    /// Independently rounds one absolute `Date` to millisecond precision.
    ///
    /// Exact halfway values in the represented `Date` round away from the Unix
    /// epoch.
    public static func roundedToMillisecond(_ date: Date) -> Date? {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded(.toNearestOrAwayFromZero)
        guard milliseconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// Reads an ISO 8601 origin as an absolute `Date` and numeric UTC offset.
    ///
    /// The offset is retained for canonical writing. Replay needs only the
    /// `Date`. Foundation owns parsing and calendar interpretation; the
    /// returned `Date` is rounded to millisecond precision.
    public static func parseOrigin(_ text: String) -> (date: Date, offsetMinutes: Int)? {
        guard let date = (try? isoStyle(fractional: true).parse(text))
            ?? (try? isoStyle(fractional: false).parse(text)),
            let roundedDate = roundedToMillisecond(date)
        else { return nil }
        return (roundedDate, parseOffsetMinutes(from: text) ?? 0)
    }

    /// Writes an origin using its absolute `Date` and retained numeric offset.
    ///
    /// The offset must be safe for Foundation's fixed-timezone format style on
    /// every supported platform.
    /// Zero writes as `Z`; a regional timezone rule is never persisted.
    public static func formatOrigin(_ date: Date, offsetMinutes: Int) -> String? {
        guard (-maximumPortableOffsetMinutes...maximumPortableOffsetMinutes).contains(offsetMinutes),
              let roundedDate = roundedToMillisecond(date),
              let timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60)
        else { return nil }

        let style = isoStyle(fractional: true, timeZone: timeZone)
        // Some Foundation releases extract the preceding millisecond from a
        // Date whose floating-point value sits just below an exact boundary.
        // Format from inside the selected millisecond.
        return style.format(roundedDate.addingTimeInterval(0.00025))
    }

    private static func parseOffsetMinutes(from text: String) -> Int? {
        let units = Array(text.utf8.suffix(6))
        let suffix = text.suffix(6)
        guard units.count == 6,
              units[0] == .plusSign || units[0] == .minusSign,
              units[1].isASCIIDigit, units[2].isASCIIDigit,
              units[3] == .colon,
              units[4].isASCIIDigit, units[5].isASCIIDigit,
              let hours = Int(suffix.dropFirst().prefix(2)),
              let minutes = Int(suffix.suffix(2)),
              hours < 24, minutes < 60
        else { return nil }

        let magnitude = hours * 60 + minutes
        let offsetMinutes = units[0] == .minusSign ? -magnitude : magnitude
        // Linux Foundation crashes while formatting some larger fixed zones.
        guard (-maximumPortableOffsetMinutes...maximumPortableOffsetMinutes).contains(offsetMinutes),
              TimeZone(secondsFromGMT: offsetMinutes * 60) != nil
        else { return nil }
        return offsetMinutes
    }

    private static func isoStyle(fractional: Bool, timeZone: TimeZone = .gmt) -> Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon,
                                includingFractionalSeconds: fractional,
                                timeZone: timeZone)
    }
}

private extension UTF8.CodeUnit {
    static let plusSign = Self(ascii: "+")
    static let minusSign = Self(ascii: "-")
    static let colon = Self(ascii: ":")
    static let digitZero = Self(ascii: "0")
    static let digitNine = Self(ascii: "9")

    var isASCIIDigit: Bool {
        self >= .digitZero && self <= .digitNine
    }
}
