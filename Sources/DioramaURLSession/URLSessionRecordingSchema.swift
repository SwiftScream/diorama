import DioramaCore
import DioramaHTTP
import DioramaPersistence

/// Version-one URLSession recording schema.
///
/// Pass the same system descriptor to the registry for all keyed URLSession attachments.
/// Prepared-value policy may vary by key. Bridge capabilities apply when preparing replay.
public struct URLSessionRecordingSchema: Sendable {
    /// Shared default registration for ordinary prepared fields and credentials.
    public static let standard = Self()

    /// The single headerless track declared by a URLSession system definition.
    public static let interactions = interactions(matching: HTTPRequestMatcher())

    /// Declares the interactions track with the same prepared matcher that setup uses for replay.
    public static func interactions(matching matcher: HTTPRequestMatcher)
        -> TrackDefinition<HTTPInteraction<URLSessionFailure>, Void>
    {
        TrackDefinition("interactions").withRecordingMerge(HTTPRecordingMerge(matcher: matcher).merge)
    }

    /// System-wide metadata for scenario persistence dispatch.
    public let systemType: ScenarioSystemType

    private static let typeID = SystemTypeID(rawValue: "diorama.urlsession")
    private let preparations: [AttachmentKey: HTTPPreparation]

    /// Configures validation of already prepared values. Unlisted keys use HTTP defaults.
    public init(preparations: [AttachmentKey: HTTPPreparation] = [:]) {
        self.preparations = preparations
        let registration = PersistentSystemRegistration(
            currentSchemaVersion: 1, payloadType: URLSessionPayload.self,
            encode: { attachment in
                let track = try Self.track(in: attachment)
                try Self.validate(track, preparations: preparations, supported: nil)
                return URLSessionPayload(interactions: track.records.map(\.value))
            }, decode: { payload, key in
                try Self.attachment(key: key, interactions: payload.interactions,
                                    preparation: preparations[key] ?? HTTPPreparation())
            })
        systemType = ScenarioSystemType(id: Self.typeID, persistence: registration)
    }

    /// Builds an attachment in invocation order using the registered reader's admission rules.
    public func attachment(key: AttachmentKey, interactions: [HTTPInteraction<URLSessionFailure>]) throws
        -> ScenarioAttachment
    {
        try Self.attachment(key: key, interactions: interactions, preparation: preparations[key] ?? HTTPPreparation())
    }

    /// Checks every interaction before handing its track to a replay system.
    /// An empty supported set advertises no operations. An empty track requires none.
    public func replayTrack(in attachment: ScenarioAttachment, supporting capabilities: Set<URLSessionReplayCapability>)
        throws -> HeaderlessSequentialTrack<HTTPInteraction<URLSessionFailure>>
    {
        let track = try Self.track(in: attachment)
        try Self.validate(track, preparations: preparations, supported: capabilities)
        return track
    }

    /// Validates the resolved baseline from a system definition's startup hook, before any factory runs.
    /// Record mode checks prepared input. Replay additionally requires the bridge's supported behaviors.
    public func validate(in context: borrowing SystemValidationContext,
                         supporting capabilities: Set<URLSessionReplayCapability>) throws
    {
        guard context.mode != .passthrough else { return }
        let profile = context.mode == .replay ? capabilities : nil
        try context.validate(Self.interactions) { track in
            try Self.validate(track, preparations: preparations, supported: profile)
        } diagnosticForFailure: { failure in
            guard let error = failure as? URLSessionRecordingError else { return nil }
            let location: URLSessionRecordingLocation
            let issue: DiagnosticLabel
            let rule: DiagnosticLabel?
            switch error {
            case let .invalidValue(value):
                location = value
                issue = DiagnosticLabel("urlsession.invalid-prepared-value")
                rule = nil
            case let .unsupported(value, capability):
                location = value
                issue = DiagnosticLabel("urlsession.unsupported-replay-capability")
                rule = capability
            }
            let path = [DiagnosticLabel("attempt"), DiagnosticLabel(index: location.attempt)] + location.fieldPath
            return Diagnostic(issue: .system(issue), context: .record(location.record), fieldPath: path, rule: rule)
        }
    }

    private static func validate(_ track: HeaderlessSequentialTrack<HTTPInteraction<URLSessionFailure>>,
                                 preparations: [AttachmentKey: HTTPPreparation],
                                 supported: Set<URLSessionReplayCapability>?) throws
    {
        let preparation = preparations[track.id.attachmentID.key] ?? HTTPPreparation()
        for record in track.records {
            var validation = URLSessionRecordingValidation(record.identity, preparation: preparation,
                                                           supported: supported)
            try validation.inspect(record.value)
        }
    }

    private static func attachment(key: AttachmentKey, interactions: [HTTPInteraction<URLSessionFailure>],
                                   preparation: HTTPPreparation) throws -> ScenarioAttachment
    {
        let id = AttachmentID(systemTypeID: typeID, key: key)
        let trackID = trackID(for: id)
        let values = try interactions.enumerated().map { index, interaction in
            let record = RecordIdentity(trackID: trackID, sequence: UInt64(index))
            var validation = URLSessionRecordingValidation(record, preparation: preparation)
            try validation.inspect(interaction)
            return try ValuePreparation<HTTPInteraction<URLSessionFailure>>().admitPrepared(
                interaction, context: .record(record))
        }
        return try ScenarioAttachment(id: id).adding(SequentialTrack(id: trackID, values: values))
    }

    private static func trackID(for id: AttachmentID) -> TrackID {
        TrackID(attachmentID: id, key: interactions.key)
    }

    private static func track(in attachment: ScenarioAttachment) throws
        -> HeaderlessSequentialTrack<HTTPInteraction<URLSessionFailure>>
    {
        let id = trackID(for: attachment.id)
        guard attachment.id.systemTypeID == typeID, attachment.trackIDs == [id],
              let track = try? attachment.track(id, as: HTTPInteraction<URLSessionFailure>.self)
        else { throw PersistentSystemEncodingError.invalidTrackLayout(attachment.id) }
        return track
    }
}

private struct URLSessionPayload: Codable, Sendable {
    let interactions: [HTTPInteraction<URLSessionFailure>]

    private enum CodingKeys: String, CodingKey, CaseIterable { case interactions }

    init(interactions: [HTTPInteraction<URLSessionFailure>]) {
        self.interactions = interactions
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.strictContainer(keyedBy: CodingKeys.self)
        interactions = try fields.decode([HTTPInteraction<URLSessionFailure>].self, forKey: .interactions)
    }
}
