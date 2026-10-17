import DioramaCore
import Foundation

/// Prepared callback content; no native objects enter a draft.
enum LocationCaptureEvent: Equatable, Sendable {
    case batch([LocationRecordedLocation])
    case failure(NSErrorSnapshot)
}

/// Runtime identity prevents a token from another execution completing a slot.
final class LocationCaptureOwner: Sendable {}

struct LocationSessionObservation: Sendable {
    let owner: LocationCaptureOwner
    let record: RecordIdentity
    let index: Int
    let timestampOrigin: TimestampOrigin
    let deliveryMilliseconds: Int64

    /// Derives latency before delivery from the reserved timeline and normalized timestamp.
    func latency(for timestamp: Date) -> Int64? {
        guard let rounded = StableTimeCodec.roundedToMillisecond(timestamp) else { return nil }
        let milliseconds = ((rounded.timeIntervalSince1970 - timestampOrigin.date.timeIntervalSince1970) * 1000)
            .rounded()
        guard let offset = Int64(exactly: milliseconds), timestampOrigin.advanced(by: offset) == rounded else {
            return nil
        }
        let (latency, overflow) = deliveryMilliseconds.subtractingReportingOverflow(offset)
        return overflow ? nil : latency
    }
}

struct LocationAccessObservation: Sendable {
    let owner: LocationCaptureOwner
    let record: RecordIdentity
    let index: Int
}

/// One session's mutable construction, protected by Core's mode-state lock.
struct LocationSessionDraft: Sendable {
    enum Slot: Sendable {
        case pending(delay: Int64)
        case prepared(delay: Int64, LocationCaptureEvent)
    }

    let timestampOrigin: TimestampOrigin
    let deliveryOrigin: Int64
    var previousDelivery: Int64
    var slots: [Slot] = []
    var invalid = false

    init(timestampOrigin: TimestampOrigin, deliveryOrigin: Int64) {
        self.timestampOrigin = timestampOrigin
        self.deliveryOrigin = deliveryOrigin
        previousDelivery = deliveryOrigin
    }

    mutating func reserve(at milliseconds: Int64) -> Int? {
        guard milliseconds >= previousDelivery else { invalid = true; return nil }
        let index = slots.count
        slots.append(.pending(delay: milliseconds - previousDelivery))
        previousDelivery = milliseconds
        return index
    }

    mutating func complete(at index: Int, with event: PreparedValue<LocationCaptureEvent>) -> Bool {
        guard slots.indices.contains(index), case let .pending(delay) = slots[index] else {
            invalid = true
            return false
        }
        slots[index] = .prepared(delay: delay, event.value)
        return true
    }

    func freeze() -> LocationSession? {
        guard !invalid else { return nil }
        var hasLocations = false
        var events: [LocationSessionEvent] = []
        for slot in slots {
            guard case let .prepared(delay, event) = slot else { return nil }
            switch event {
            case let .failure(error):
                events.append(.failure(delayMilliseconds: delay, error: error))
            case let .batch(locations):
                hasLocations = hasLocations || !locations.isEmpty
                events.append(.batch(delayMilliseconds: delay, locations: locations))
            }
        }
        return try? LocationSession(
            timestampOrigin: hasLocations ? .observed(timestampOrigin) : nil, events: events)
    }
}

/// Notifications belong to exactly one initial or request-anchored segment.
struct LocationAccessDraft: Sendable {
    enum Slot: Sendable {
        case pending(delay: Int64)
        case prepared(LocationAccessNotification)
    }

    let request: LocationAuthorizationRequest?
    var previousDelivery: Int64
    var slots: [Slot] = []
    var invalid = false

    mutating func reserve(at milliseconds: Int64) -> Int? {
        guard milliseconds >= previousDelivery else { invalid = true; return nil }
        let index = slots.count
        slots.append(.pending(delay: milliseconds - previousDelivery))
        previousDelivery = milliseconds
        return index
    }

    mutating func complete(at index: Int, with state: PreparedValue<LocationRecordedAccessState>) -> Bool {
        guard slots.indices.contains(index), case let .pending(delay) = slots[index] else {
            invalid = true
            return false
        }
        slots[index] = .prepared(LocationAccessNotification(delayMilliseconds: delay, state: state.value))
        return true
    }

    func freeze() -> LocationTracks.AccessSegment? {
        guard !invalid else { return nil }
        var notifications: [LocationAccessNotification] = []
        for slot in slots {
            guard case let .prepared(notification) = slot else { return nil }
            notifications.append(notification)
        }
        if let request {
            return .request(LocationAccessRequestSegment(request: request, notifications: notifications))
        }
        return .initial(notifications)
    }
}
