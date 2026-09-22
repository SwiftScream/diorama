/// Copies only the identity layout and verification policy needed at finish.
struct ExecutionUsage: Sendable {
    struct Attachment: Sendable {
        let id: AttachmentID
        let mode: ScenarioMode
        let allowsUnusedReplayRecords: Bool
        let tracks: [TrackID]
    }

    let active: [Attachment]

    init(definition: ScenarioDefinition, defaultMode: ScenarioMode, systems: [AnyScenarioSystem]) {
        active = definition.attachments.map { attachment in
            guard let system = systems.first(where: { $0.attachmentID == attachment.id }) else {
                preconditionFailure("Validated system registration is missing")
            }
            return Attachment(id: attachment.id, mode: system.effectiveMode(defaultMode: defaultMode),
                              allowsUnusedReplayRecords: system.allowsUnusedReplayRecords, tracks: attachment.trackIDs)
        }
    }

    func snapshot(_ tracks: [SequentialTrackUsage]) -> [AttachmentUsage] {
        active.map { attachment in
            AttachmentUsage(attachmentID: attachment.id, mode: attachment.mode,
                            allowsUnusedReplayRecords: attachment.allowsUnusedReplayRecords,
                            tracks: attachment.tracks.map { id in
                                guard let track = tracks.first(where: { $0.id == id }) else {
                                    preconditionFailure("An activated track must contribute final usage")
                                }
                                return track
                            })
        }
    }
}
