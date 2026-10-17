import DioramaCore

/// Location-owned incremental capture, accessed only through Core's protected state.
/// Reservations precede conversion; only prepared content can complete them.
struct LocationCaptureState: Sendable {
    let sessions: SequentialTrackLease<LocationSession, LocationTracks.SessionHeader>
    let access: SequentialTrackLease<LocationTracks.AccessSegment, LocationRecordedAccessState>
    private let owner = LocationCaptureOwner()
    private var sessionDrafts: [RecordIdentity: LocationSessionDraft] = [:]
    private var accessDrafts: [RecordIdentity: LocationAccessDraft] = [:]
    private var activeSession: RecordIdentity?
    private var activeAccess: RecordIdentity?

    init(
        sessions: SequentialTrackLease<LocationSession, LocationTracks.SessionHeader>,
        access: SequentialTrackLease<LocationTracks.AccessSegment, LocationRecordedAccessState>)
    {
        self.sessions = sessions
        self.access = access
    }

    /// Repeated active starts reserve no additional session.
    mutating func startSession(
        timestampOrigin: TimestampOrigin, operation: inout SystemOperation<Self>) throws
    {
        guard activeSession == nil else { return }
        let anchor = try milliseconds(on: sessions.id, operation: &operation)
        let identity = try operation.beginRecord(
            on: sessions, preparation: ValuePreparation<LocationSession>(), capturing: { identity in
                sessionDrafts[identity] = LocationSessionDraft(timestampOrigin: timestampOrigin, deliveryOrigin: anchor)
                return identity
            }, freeze: { state, identity in
                if state.activeSession == identity {
                    state.activeSession = nil
                }
                return state.sessionDrafts.removeValue(forKey: identity)?.freeze()
            })
        activeSession = identity
    }

    /// Stop closes observation admission, preserving an open recording horizon.
    /// Already reserved conversions may still complete before Core freezes.
    mutating func stopSession() {
        activeSession = nil
    }

    mutating func reserveSessionEvent(operation: inout SystemOperation<Self>) throws -> LocationSessionObservation? {
        guard let record = activeSession else { return nil }
        let instant: Int64
        do {
            instant = try milliseconds(on: sessions.id, operation: &operation)
        } catch {
            sessionDrafts[record]?.invalid = true
            throw error
        }
        guard let timestampOrigin = sessionDrafts[record]?.timestampOrigin,
              let deliveryOrigin = sessionDrafts[record]?.deliveryOrigin,
              let index = sessionDrafts[record]?.reserve(at: instant)
        else {
            invalidate(record, operation: &operation)
            return nil
        }
        return LocationSessionObservation(
            owner: owner, record: record, index: index,
            timestampOrigin: timestampOrigin, deliveryMilliseconds: instant - deliveryOrigin)
    }

    @discardableResult
    mutating func complete(
        _ observation: LocationSessionObservation, with event: PreparedValue<LocationCaptureEvent>,
        operation: inout SystemOperation<Self>) -> Bool
    {
        guard observation.owner === owner,
              sessionDrafts[observation.record]?.complete(at: observation.index, with: event) == true
        else {
            invalidate(observation.record, operation: &operation)
            return false
        }
        return true
    }

    /// Starts the initial segment once. Requests can also establish this empty prefix.
    mutating func beginAccess(operation: inout SystemOperation<Self>) throws {
        guard activeAccess == nil else { return }
        try beginAccessSegment(request: nil, operation: &operation)
    }

    /// Each request seals the preceding segment and reserves its own Core record.
    mutating func requestAuthorization(
        _ request: LocationAuthorizationRequest, operation: inout SystemOperation<Self>) throws
    {
        try beginAccess(operation: &operation)
        try beginAccessSegment(request: request, operation: &operation)
    }

    mutating func reserveAccessNotification(operation: inout SystemOperation<Self>) throws
        -> LocationAccessObservation?
    {
        guard let record = activeAccess else { return nil }
        let instant: Int64
        do {
            instant = try milliseconds(on: access.id, operation: &operation)
        } catch {
            accessDrafts[record]?.invalid = true
            throw error
        }
        guard let index = accessDrafts[record]?.reserve(at: instant) else {
            invalidate(record, operation: &operation)
            return nil
        }
        return LocationAccessObservation(owner: owner, record: record, index: index)
    }

    @discardableResult
    mutating func complete(
        _ observation: LocationAccessObservation, with value: PreparedValue<LocationRecordedAccessState>,
        operation: inout SystemOperation<Self>) -> Bool
    {
        guard observation.owner === owner,
              accessDrafts[observation.record]?.complete(at: observation.index, with: value) == true
        else {
            invalidate(observation.record, operation: &operation)
            return false
        }
        return true
    }

    private mutating func beginAccessSegment(
        request: LocationAuthorizationRequest?, operation: inout SystemOperation<Self>) throws
    {
        let anchor = try milliseconds(on: access.id, operation: &operation)
        let identity = try operation.beginRecord(
            on: access, preparation: ValuePreparation<LocationTracks.AccessSegment>(), capturing: { identity in
                accessDrafts[identity] = LocationAccessDraft(request: request, previousDelivery: anchor)
                return identity
            }, freeze: { state, identity in
                if state.activeAccess == identity {
                    state.activeAccess = nil
                }
                return state.accessDrafts.removeValue(forKey: identity)?.freeze()
            })
        activeAccess = identity
    }

    private func milliseconds(on track: TrackID, operation: inout SystemOperation<Self>) throws -> Int64 {
        do {
            let capture = try operation.time.capture()
            let components = try operation.time.logicalTime(at: capture).components
            let (whole, overflow) = components.seconds.multipliedReportingOverflow(by: 1000)
            let fraction = (components.attoseconds + 500_000_000_000_000) / 1_000_000_000_000_000
            let (value, additionOverflow) = whole.addingReportingOverflow(fraction)
            guard !overflow, !additionOverflow, value >= 0 else { throw LocationCaptureError.invalidTime }
            return value
        } catch {
            operation.report(Diagnostic(issue: .conversionFailed, context: .track(track),
                                        recordingImpact: .invalidatesCandidate))
            throw error
        }
    }

    private func invalidate(_ record: RecordIdentity, operation: inout SystemOperation<Self>) {
        operation.report(Diagnostic(issue: .conversionFailed, context: .record(record),
                                    recordingImpact: .invalidatesCandidate))
    }
}

private enum LocationCaptureError: Error {
    case invalidTime
}
