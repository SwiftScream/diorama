/// Checked arithmetic for nonnegative execution-relative durations.
extension Duration {
    /// Largest logical duration before the origin-specific timer-range check.
    static let maximumLogicalTime = Duration(
        secondsComponent: Int64.max, attosecondsComponent: 999_999_999_999_999_999)

    /// Adds a nonnegative delay without exceeding the supported logical range.
    func checkedLogicalTime(adding delay: Duration) -> Duration? {
        // Duration's storage is wider than its Int64 seconds component.
        // Reject oversized operands before asking for components, which traps.
        guard self >= .zero, self <= .maximumLogicalTime,
              delay >= .zero, delay <= .maximumLogicalTime else { return nil }
        return Self.checkedLogicalDuration(attoseconds: logicalAttoseconds + delay.logicalAttoseconds)
    }

    /// Measures a nonnegative interval between execution-relative times.
    func checkedElapsed(since earlier: Duration) -> Duration? {
        guard earlier >= .zero, self >= earlier, self <= .maximumLogicalTime else { return nil }
        return Self.checkedLogicalDuration(attoseconds: logicalAttoseconds - earlier.logicalAttoseconds)
    }

    private static let attosecondsPerSecond = Int128(1_000_000_000_000_000_000)

    private var logicalAttoseconds: Int128 {
        let parts = components
        return Int128(parts.seconds) * Self.attosecondsPerSecond + Int128(parts.attoseconds)
    }

    private static func checkedLogicalDuration(attoseconds: Int128) -> Duration? {
        guard attoseconds >= 0 else { return nil }
        let seconds = attoseconds / attosecondsPerSecond
        guard seconds <= Int128(Int64.max) else { return nil }
        return Duration(secondsComponent: Int64(seconds),
                        attosecondsComponent: Int64(attoseconds % attosecondsPerSecond))
    }
}
