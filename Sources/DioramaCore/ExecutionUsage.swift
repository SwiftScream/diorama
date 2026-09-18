/// Copies only the identity layout and verification policy needed at finish.
struct ExecutionUsage: Sendable {
    struct Attachment: Sendable {
        let id: AttachmentID
        let mode: ScenarioMode
        let ignored: Bool
        let tracks: [TrackID]
    }

    let active: [Attachment]

    init(definition: ScenarioDefinition) {
        active = definition.attachments.map {
            Attachment(id: $0.id, mode: $0.modeOverride ?? definition.defaultMode,
                       ignored: definition.ignoredAttachments.contains($0.id.key), tracks: $0.trackIDs)
        }
    }

    func snapshot(_ tracks: [SequentialTrackUsage]) -> [AttachmentUsage] {
        active.map { attachment in
            AttachmentUsage(attachmentID: attachment.id, mode: attachment.mode, isIgnored: attachment.ignored,
                            tracks: attachment.tracks.map { id in
                                guard let track = tracks.first(where: { $0.id == id }) else {
                                    preconditionFailure("An activated track must contribute final usage")
                                }
                                return track
                            })
        }
    }
}
