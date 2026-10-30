import DioramaCore
import DioramaPersistence

/// Prepared Core layout for a Location attachment's two claim sequences.
enum LocationTracks {
    static let type = ScenarioSystemType("diorama.location", persistence: LocationPersistence.registration)
    private static let sessionsKey = TrackKey(rawValue: "sessions")
    private static let accessKey = TrackKey(rawValue: "access")

    struct SessionHeader: Equatable, Sendable {
        let coordinateSpace: LocationHorizontalSpace?
        let altitudeOrigin: LocationAltitudeOrigin?
        let initial: LocationInitialSnapshot?
    }

    enum AccessSegment: Equatable, Sendable {
        case initial([LocationAccessNotification])
        case request(LocationAccessRequestSegment)
    }

    static func attachment(named name: String, recording: LocationRecording) throws -> ScenarioAttachment {
        let id = AttachmentID(systemTypeID: type.id, key: AttachmentKey(rawValue: name))
        let sessionID = TrackID(attachmentID: id, key: sessionsKey)
        let accessID = TrackID(attachmentID: id, key: accessKey)
        let header = SessionHeader(
            coordinateSpace: recording.coordinateSpace,
            altitudeOrigin: recording.altitudeOrigin,
            initial: recording.initial)
        let sessionPreparation = ValuePreparation<LocationSession>()
        let sessions = try recording.sessions.enumerated().map { index, session in
            try sessionPreparation.admitPrepared(
                session, context: .record(RecordIdentity(trackID: sessionID, sequence: UInt64(index))))
        }
        let segments: [AccessSegment] = [.initial(recording.access.initialNotifications)]
            + recording.access.requests.map(AccessSegment.request)
        let accessPreparation = ValuePreparation<AccessSegment>()
        let access = try segments.enumerated().map { index, segment in
            try accessPreparation.admitPrepared(
                segment, context: .record(RecordIdentity(trackID: accessID, sequence: UInt64(index))))
        }
        return try ScenarioAttachment(id: id)
            .adding(SequentialTrack(
                id: sessionID,
                header: ValuePreparation<SessionHeader>().admitPrepared(header, context: .track(sessionID)),
                values: sessions))
            .adding(SequentialTrack(
                id: accessID,
                header: ValuePreparation<LocationRecordedAccessState>().admitPrepared(
                    recording.access.initialState, context: .track(accessID)),
                values: access))
    }

    static func recording(in attachment: ScenarioAttachment) throws -> LocationRecording {
        guard attachment.id.systemTypeID == type.id else { throw LocationRecordingError.invalidTrackLayout }
        let sessionID = TrackID(attachmentID: attachment.id, key: sessionsKey)
        let accessID = TrackID(attachmentID: attachment.id, key: accessKey)
        guard attachment.trackIDs == [sessionID, accessID],
              let sessions = try? attachment.track(sessionID, as: LocationSession.self, header: SessionHeader.self),
              let access = try? attachment.track(
                  accessID, as: AccessSegment.self, header: LocationRecordedAccessState.self),
              let first = access.records.first,
              case let .initial(initialNotifications) = first.value
        else { throw LocationRecordingError.invalidTrackLayout }
        var requests: [LocationAccessRequestSegment] = []
        for record in access.records.dropFirst() {
            guard case let .request(request) = record.value else {
                throw LocationRecordingError.invalidTrackLayout
            }
            requests.append(request)
        }
        return try LocationRecording(
            coordinateSpace: sessions.header.coordinateSpace,
            altitudeOrigin: sessions.header.altitudeOrigin,
            initial: sessions.header.initial,
            sessions: sessions.records.map(\.value),
            access: LocationAccessRecording(
                initialState: access.header,
                initialNotifications: initialNotifications,
                requests: requests))
    }
}
