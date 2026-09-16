extension ScenarioDefinition {
    static func validateInventory(
        _ tracks: [UnattachedTrack], active: [AttachmentKey: AttachmentID], ignored: Set<AttachmentKey>) throws
    {
        var known = active
        var trackIDs: Set<TrackID> = []
        for track in tracks {
            let id = track.id.attachmentID
            if let existing = known[id.key], existing != id {
                throw ScenarioDefinitionError.incompatibleAttachmentSystem(
                    key: id.key, existing: existing.systemTypeID, proposed: id.systemTypeID)
            }
            guard active[id.key] == nil else { throw ScenarioDefinitionError.duplicateAttachment(id) }
            guard trackIDs.insert(track.id).inserted else { throw ScenarioDefinitionError.duplicateTrack(track.id) }
            known[id.key] = id
        }
        for key in ignored.sorted(by: { $0.rawValue < $1.rawValue }) where known[key] == nil {
            throw ScenarioDefinitionError.unknownIgnoredAttachment(key)
        }
    }
}

/// Copies only the identity layout and verification policy needed at finish.
struct ExecutionUsage: Sendable {
    struct Attachment: Sendable {
        let id: AttachmentID
        let mode: ScenarioMode
        let ignored: Bool
        let tracks: [TrackID]
    }

    let active: [Attachment]
    let unattached: [AttachmentUsage]

    init(definition: ScenarioDefinition) {
        active = definition.attachments.map {
            Attachment(id: $0.id, mode: $0.modeOverride ?? definition.defaultMode,
                       ignored: definition.ignoredAttachments.contains($0.id.key), tracks: $0.trackIDs)
        }
        var inventory: [AttachmentUsage] = []
        for track in definition.unattachedTracks {
            let id = track.id.attachmentID
            guard !inventory.contains(where: { $0.attachmentID == id }) else { continue }
            inventory.append(AttachmentUsage(
                attachmentID: id, mode: nil, isIgnored: definition.ignoredAttachments.contains(id.key),
                tracks: definition.unattachedTracks.filter { $0.id.attachmentID == id }.map {
                    SequentialTrackUsage(id: $0.id, activity: .unattached(recordCount: $0.recordCount))
                }))
        }
        unattached = inventory
    }

    func diagnoseUnattached(reporter: DiagnosticReporter) {
        for attachment in unattached where !attachment.isIgnored {
            reporter.record(Diagnostic(issue: .verification(.unattachedRecording),
                                       context: .attachment(attachment.attachmentID)))
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
        } + unattached
    }
}
