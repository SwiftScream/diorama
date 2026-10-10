/// Prepared tracks for one attachment and execution, recovered by key and types.
struct PreparedTrackRegistry: Sendable {
    let entries: [TrackKey: any PreparedTrackEntry]
    let attachmentID: AttachmentID
    let reporter: DiagnosticReporter

    func entry<Value: Sendable, Header: Sendable>(
        for definition: TrackDefinition<Value, Header>) throws -> any PreparedTrackEntry<Value, Header>
    {
        guard let entry = entries[definition.key] as? any PreparedTrackEntry<Value, Header> else {
            let diagnostic = Diagnostic(issue: .lifecycle(.invalidTrackRequest), context: .track(
                TrackID(attachmentID: attachmentID, key: definition.key)))
            reporter.record(diagnostic)
            throw PreparationFailure(diagnostic: diagnostic)
        }
        return entry
    }
}
