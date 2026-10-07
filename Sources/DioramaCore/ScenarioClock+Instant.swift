public extension ScenarioClock {
    /// An identity-free logical offset from the receiving execution's origin.
    ///
    /// Negative offsets represent already-passed deadlines. Values range from
    /// minus to plus `Int64.max` seconds and 999,999,999,999,999,999 attoseconds.
    /// Construction, arithmetic operands, and results outside that symmetric
    /// range fail a programmer precondition. Instants have no persisted form.
    struct Instant: InstantProtocol, Hashable, Sendable {
        /// The duration relative to the start of whichever execution uses it.
        public let offset: Duration

        /// Creates a transferable logical offset, checking the supported range.
        public init(offset: Duration) {
            precondition(Self.supports(offset), "Logical instant is outside the supported duration range")
            self.offset = offset
        }

        /// Advances by a signed duration using checked logical arithmetic.
        public func advanced(by duration: Duration) -> Self {
            precondition(Self.supports(duration), "Logical advance is outside the supported duration range")
            // Both operands are bounded far below Duration's Int128 storage
            // limits, so addition cannot overflow before the result is checked.
            return Self(offset: offset + duration)
        }

        /// Measures a signed interval, checking the supported duration range.
        public func duration(to other: Self) -> Duration {
            let duration = other.offset - offset
            precondition(Self.supports(duration), "Logical interval is outside the supported duration range")
            return duration
        }

        /// Compares offsets without attachment or execution identity.
        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.offset < rhs.offset
        }

        private static func supports(_ value: Duration) -> Bool {
            value >= .zero - .maximumLogicalTime && value <= .maximumLogicalTime
        }
    }
}
