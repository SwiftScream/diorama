/// A noncopyable, nonescaping token for effects inside one state operation.
/// Core retains diagnostic facts immediately and delivers notifications after
/// the state lock is released. Do not store or capture this token.
public struct SystemOperation<State: Sendable>: ~Copyable {
    let runtime: SystemRuntime<State>
    let reporter: DiagnosticReporter

    /// Reserves a position before capture and admits a complete stable value.
    @discardableResult
    public func record<Value: Sendable>(
        on lease: SequentialTrackLease<Value, some Sendable>,
        capturing capture: () throws -> Value,
        preparation: ValuePreparation<Value>) throws -> RecordIdentity
    {
        try lease.record(capturing: capture, preparation: preparation)
    }

    /// Consumes the next value atomically within this managed operation.
    public func consumeNext<Value: Sendable>(
        on lease: SequentialTrackLease<Value, some Sendable>) throws -> Value
    {
        try lease.consumeNext()
    }

    /// Captures a track header using its system-owned policy.
    public func setHeader<Header: Sendable>(
        on lease: SequentialTrackLease<some Sendable, Header>, capturing capture: () throws -> Header,
        preparation: ValuePreparation<Header>) throws
    {
        try lease.setHeader(capturing: capture, preparation: preparation)
    }

    /// Reports a safe fact, retaining it before the operation unlocks.
    public func report(_ diagnostic: Diagnostic) {
        reporter.record(diagnostic)
    }

    /// Reports against one track, respecting its closed lifetime.
    @discardableResult
    public func report(
        on lease: SequentialTrackLease<some Sendable, some Sendable>, _ issue: DiagnosticIssue,
        recordingImpact: RecordingImpact = .none) -> Bool
    {
        lease.report(issue, recordingImpact: recordingImpact)
    }

    /// Selects and exclusively claims a record without consuming it.
    public func claim<Value: Sendable, Input: Sendable>(
        on lease: SequentialTrackLease<Value, some Sendable>, matching input: Input,
        using selector: ReplaySelector<Input, Value>) throws -> ReplayClaim<Value>
    {
        try lease.claim(matching: input, using: selector)
    }

    /// Registers an incremental record. Freeze receives the same protected
    /// mode state, once, after admitted observations drain. A registration that
    /// races closure also freezes once, after the current operation unlocks.
    public func beginRecord<Value: Sendable, Accumulator: Sendable>(
        on lease: SequentialTrackLease<Value, some Sendable>, preparation: ValuePreparation<Value>,
        capturing capture: (RecordIdentity) throws -> Accumulator,
        freeze: @escaping @Sendable (inout State, Accumulator) -> Value?) throws -> Accumulator
    {
        let runtime = runtime
        return try lease.beginRecord(preparation: preparation, capturing: capture) { accumulator in
            runtime.freeze { freeze(&$0, accumulator) } ?? nil
        }
    }
}
