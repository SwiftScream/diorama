/// Copies identity metadata only; never retains heterogeneous track content.
struct DiagnosticOrdering: Sendable {
    let attachments: [AttachmentID]
    let tracks: [TrackID]

    init(attachments: [ScenarioAttachment]) {
        self.attachments = attachments.map(\.id)
        tracks = attachments.flatMap(\.trackIDs)
    }

    func precedes(_ lhs: ReportedDiagnostic, _ rhs: ReportedDiagnostic) -> Bool {
        let left = lhs.diagnostic.context
        let right = rhs.diagnostic.context
        if left.attachmentID != right.attachmentID {
            return attachmentPrecedes(left.attachmentID, right.attachmentID)
        }
        if left.trackID != right.trackID {
            return trackPrecedes(left.trackID, right.trackID)
        }
        let leftSequence = left.recordIdentity?.sequence
        let rightSequence = right.recordIdentity?.sequence
        if leftSequence != rightSequence {
            guard let leftSequence else { return true }
            guard let rightSequence else { return false }
            return leftSequence < rightSequence
        }
        return lhs.sequence < rhs.sequence
    }

    private func attachmentPrecedes(_ lhs: AttachmentID?, _ rhs: AttachmentID?) -> Bool {
        guard let lhs else { return true }
        guard let rhs else { return false }
        let leftIndex = attachments.firstIndex(of: lhs) ?? Int.max
        let rightIndex = attachments.firstIndex(of: rhs) ?? Int.max
        if leftIndex != rightIndex {
            return leftIndex < rightIndex
        }
        return (lhs.systemTypeID.rawValue, lhs.key.rawValue) < (rhs.systemTypeID.rawValue, rhs.key.rawValue)
    }

    private func trackPrecedes(_ lhs: TrackID?, _ rhs: TrackID?) -> Bool {
        guard let lhs else { return true }
        guard let rhs else { return false }
        let leftIndex = tracks.firstIndex(of: lhs) ?? Int.max
        let rightIndex = tracks.firstIndex(of: rhs) ?? Int.max
        if leftIndex != rightIndex {
            return leftIndex < rightIndex
        }
        return lhs.key.rawValue < rhs.key.rawValue
    }
}
