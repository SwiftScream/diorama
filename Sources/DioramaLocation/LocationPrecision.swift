import Foundation

/// One decimal quantization policy for consumer values and persisted numbers.
/// A normalized Double approximates the chosen decimal; encoding keeps the decimal.
enum LocationPrecision: Int {
    case measurement = 3
    case coordinate = 8

    static func millimeters(_ value: Double) -> Double {
        measurement.normalized(value)
    }

    static func coordinateDegrees(_ value: Double) -> Double {
        coordinate.normalized(value)
    }

    static func courseDegrees(_ value: Double) -> Double {
        measurement.normalized(value)
    }

    /// Returns the rounded decimal directly for encoding, without a Double conversion.
    /// Nil denotes a value outside Decimal's range; finite whole Doubles need no rounding.
    func decimalRepresentation(of value: Double) -> Decimal? {
        guard value.isFinite else { return nil }
        let scale = self == .coordinate ? 100_000_000.0 : 1000.0
        guard abs(value) >= 0.5 / scale else { return Decimal.zero }
        guard var decimal = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        var result = Decimal()
        NSDecimalRound(&result, &decimal, rawValue, .plain)
        return result
    }

    /// Decimal halfway cases use the shortest decimal spelling of the observed Double.
    /// The returned binary approximation is the value used by both delivery paths.
    private func normalized(_ value: Double) -> Double {
        guard value != 0 else { return 0 }
        // Whole values need no rounding; this also avoids Decimal range limits.
        guard value.rounded() != value else { return value }
        guard let decimal = decimalRepresentation(of: value),
              let rounded = Double(NSDecimalNumber(decimal: decimal).stringValue)
        else { preconditionFailure("Validated fractional measurement must fit Decimal and Double") }
        return rounded == 0 ? 0 : rounded
    }
}
