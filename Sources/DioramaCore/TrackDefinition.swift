/// An immutable typed track definition, reusable across keyed instances and runs.
/// Register one definition per track key. Lookup uses the key and value/header
/// types; initial content and policies come from the registered definition.
public struct TrackDefinition<Value: Sendable, Header: Sendable>: Sendable {
    /// Stable key within the system attachment.
    public let key: TrackKey
    private let header: PreparedValue<Header>
    private let values: [PreparedValue<Value>]
    private let preparation: ValuePreparation<Value>
    private let headerPreparation: ValuePreparation<Header>
    private let continuation: ReplayContinuationPolicy<Value>
    private var makeMerge: @Sendable (DiagnosticReporter) -> RecordingMerge<Value, Header>?

    /// Declares a headered track and its admission and recording policies.
    public init(
        _ key: String, header: PreparedValue<Header>, values: [PreparedValue<Value>] = [],
        preparation: ValuePreparation<Value> = .init(),
        headerPreparation: ValuePreparation<Header> = .init(),
        continuationPolicy: ReplayContinuationPolicy<Value> = .error,
        mergeRecording: RecordingMerge<Value, Header>? = nil)
    {
        self.key = TrackKey(rawValue: key)
        self.header = header
        self.values = values
        self.preparation = preparation
        self.headerPreparation = headerPreparation
        continuation = continuationPolicy
        makeMerge = { _ in mergeRecording }
    }

    /// Configures a final recording merge that can report safe domain facts for this run.
    /// The reporting function is scoped to the merge. Throw to refuse the candidate.
    public func withRecordingMerge(
        _ merge: @escaping @Sendable (
            SequentialTrack<Value, Header>, SequentialTrack<Value, Header>, (Diagnostic) -> Void)
            throws -> SequentialTrack<Value, Header>) -> Self
    {
        var definition = self
        definition.makeMerge = { reporter in
            { baseline, fresh in try merge(baseline, fresh, reporter.record) }
        }
        return definition
    }

    /// Erases this definition only at Core's heterogeneous layout boundary.
    public var erased: AnyTrackDefinition {
        AnyTrackDefinition(key: key, add: { attachment in
            try attachment.adding(SequentialTrack(
                id: TrackID(attachmentID: attachment.id, key: key), header: header, values: values))
        }, prepare: { context in
            let id = TrackID(attachmentID: context.attachmentID, key: key)
            let lease = try context.lease(for: id, preparation: preparation,
                                          headerPreparation: headerPreparation,
                                          continuationPolicy: continuation, mergeRecording: makeMerge(context.reporter))
            guard let header = lease.baselineHeader() else {
                throw ScenarioLifecycleIssue.invalidTrackRequest
            }
            return PreparedTrack(lease: lease, content: SequentialTrack(
                id: id, header: header, preparedRecords: lease.baselineRecords()))
        })
    }
}

public extension TrackDefinition where Header == Void {
    /// Declares a headerless track and its system-owned policies.
    init(_ key: String, values: [PreparedValue<Value>] = [],
         preparation: ValuePreparation<Value> = .init(),
         continuationPolicy: ReplayContinuationPolicy<Value> = .error,
         mergeRecording: RecordingMerge<Value, Void>? = nil)
    {
        self.init(key, header: .init(), values: values, preparation: preparation,
                  continuationPolicy: continuationPolicy, mergeRecording: mergeRecording)
    }
}

/// A typed track definition erased for heterogeneous attachment layout.
public struct AnyTrackDefinition: Sendable {
    let key: TrackKey
    let add: @Sendable (ScenarioAttachment) throws -> ScenarioAttachment
    let prepare: @Sendable (SystemPreparationContext) throws -> any PreparedTrackEntry
}
