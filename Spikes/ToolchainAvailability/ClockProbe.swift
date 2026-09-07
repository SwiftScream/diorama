import Foundation

#if os(Linux)
import FoundationNetworking
#endif

// An isolated standard-library conformance probe, not Diorama's logical clock.
private struct ForwardingClock: Clock {
    typealias Instant = ContinuousClock.Instant

    private let base = ContinuousClock()

    var now: Instant { base.now }
    var minimumResolution: Duration { base.minimumResolution }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await base.sleep(until: deadline, tolerance: tolerance)
    }
}

private func requireSendable<T: Sendable>(_: T) {}

@main
private enum ClockProbe {
    static func main() async throws {
        let clock = ForwardingClock()
        let delay = Duration.milliseconds(20)
        let start = clock.now
        let deadline = start.advanced(by: delay)
        requireSendable(clock)
        requireSendable(start)
        requireSendable(delay)
        precondition(start.duration(to: deadline) == delay)
        precondition(clock.minimumResolution > .zero)
        try await clock.sleep(until: deadline, tolerance: .zero)
        precondition(clock.now >= deadline, "Clock sleep returned before its deadline")

        let sleeper = Task {
            try await clock.sleep(until: clock.now.advanced(by: .seconds(60)), tolerance: .zero)
        }
        sleeper.cancel()
        do {
            try await sleeper.value
            preconditionFailure("Cancelled clock sleep completed successfully")
        } catch is CancellationError {
            // A cancelled native sleep has the required failure channel.
        }

        // Foundation primitives needed by DD15/DD16; this is not a stable codec.
        let instant = Date(timeIntervalSince1970: 1_893_456_000.125)
        requireSendable(instant)
        let zone = TimeZone(secondsFromGMT: 11 * 60 * 60)!
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let encoded = formatter.string(from: instant)
        precondition(encoded.hasSuffix("+11:00"))
        precondition(formatter.date(from: encoded) == instant)

        #if os(Linux)
        // Load FoundationNetworking for the Linux linkage inventory without I/O.
        let request = URLRequest(url: URL(string: "https://example.invalid")!)
        precondition(request.url?.host == "example.invalid")
        #endif
        print("PASS: Clock conformance, Duration, Sendable, deadline, cancellation, Date/ISO8601/TimeZone")
    }
}
