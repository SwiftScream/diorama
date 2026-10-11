/// An immutable typed declaration, reusable across keyed instances and runs.
/// Copies preserve declaration identity. A new declaration with the same key
/// cannot retrieve this declaration's prepared content or lease.
public struct SystemTrack<Value: Sendable, Header: Sendable>: Sendable {
    final class Identity: Sendable {}

    let identity = Identity()
    /// Stable key within the system attachment.
    public let key: TrackKey
    private let header: PreparedValue<Header>
    private let values: [PreparedValue<Value>]
    private let preparation: ValuePreparation<Value>
    private let headerPreparation: ValuePreparation<Header>
    private let merge: RecordingMerge<Value, Header>?

    /// Declares a headered track and its admission and recording policies.
    public init(
        _ key: String, header: PreparedValue<Header>, values: [PreparedValue<Value>] = [],
        preparation: ValuePreparation<Value> = .init(),
        headerPreparation: ValuePreparation<Header> = .init(),
        mergeRecording: RecordingMerge<Value, Header>? = nil)
    {
        self.key = TrackKey(rawValue: key)
        self.header = header
        self.values = values
        self.preparation = preparation
        self.headerPreparation = headerPreparation
        merge = mergeRecording
    }

    /// Erases this declaration only at Core's heterogeneous layout boundary.
    public var erased: AnySystemTrack {
        AnySystemTrack(identity: ObjectIdentifier(identity), add: { attachment in
            try attachment.adding(SequentialTrack(
                id: TrackID(attachmentID: attachment.id, key: key), header: header, values: values))
        }, prepare: { context in
            let id = TrackID(attachmentID: context.attachmentID, key: key)
            let lease = try context.lease(for: id, preparation: preparation,
                                          headerPreparation: headerPreparation,
                                          mergeRecording: merge)
            guard let header = lease.baselineHeader() else {
                throw ScenarioLifecycleIssue.invalidTrackRequest
            }
            return PreparedSystemTrack(lease: lease, content: SequentialTrack(
                id: id, header: header, preparedRecords: lease.baselineRecords()))
        })
    }
}

public extension SystemTrack where Header == Void {
    /// Declares a headerless track and its system-owned policies.
    init(_ key: String, values: [PreparedValue<Value>] = [],
         preparation: ValuePreparation<Value> = .init(),
         mergeRecording: RecordingMerge<Value, Void>? = nil)
    {
        self.init(key, header: .init(), values: values, preparation: preparation,
                  mergeRecording: mergeRecording)
    }
}

/// A typed system declaration erased for heterogeneous attachment layout.
public struct AnySystemTrack: Sendable {
    let identity: ObjectIdentifier
    let add: @Sendable (ScenarioAttachment) throws -> ScenarioAttachment
    let prepare: @Sendable (SystemPreparationContext) throws -> any Sendable
}

struct PreparedSystemTrack<Value: Sendable, Header: Sendable>: Sendable {
    let lease: SequentialTrackLease<Value, Header>
    let content: SequentialTrack<Value, Header>
}

struct SystemTrackRegistry: Sendable {
    let entries: [ObjectIdentifier: any Sendable]
    let attachmentID: AttachmentID
    let reporter: DiagnosticReporter

    func entry<Value: Sendable, Header: Sendable>(
        for track: SystemTrack<Value, Header>) throws -> PreparedSystemTrack<Value, Header>
    {
        guard let entry = entries[ObjectIdentifier(track.identity)] as? PreparedSystemTrack<Value, Header> else {
            let diagnostic = Diagnostic(issue: .lifecycle(.invalidTrackRequest), context: .track(
                TrackID(attachmentID: attachmentID, key: track.key)))
            reporter.record(diagnostic)
            throw PreparationFailure(diagnostic: diagnostic)
        }
        return entry
    }
}
