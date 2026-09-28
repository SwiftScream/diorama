/// The same runtime clock supplies capture and replay waits in one execution.
struct ExecutionClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (ContinuousClock.Instant, Duration) async throws -> Void

    static func continuous() -> Self {
        let clock = ContinuousClock()
        return Self(now: { clock.now }, sleep: { deadline, tolerance in
            try await clock.sleep(until: deadline, tolerance: tolerance)
        })
    }
}

/// A serialized read of the execution origin and its current logical time.
struct ExecutionTimeReading: Sendable {
    let time: Duration
    let order: UInt64?
    let origin: ContinuousClock.Instant
    let clock: ExecutionClock
}
