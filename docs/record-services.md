# Typed record services

This guide describes the recording services established by
[accepted Decision 19](design-decisions/19-system-owned-records.md). It
replaces the historical [grouped lifecycle API](grouped-lifecycle-recording.md).
The owning system defines its strict record value and runtime lifecycle.

## Record ownership

A `SequentialTrack<Value, Header>` supplies stable identities and ordering for
any `Sendable` value. `Sequential` describes stored order. Immediate and
incremental capture share the same record positions and final validation.
DD19 also defines separate replay-selection and consumption services; their
API guide accompanies that implementation.

Use `record(capturing:preparation:)` for immediate recording, as in the random
system. It reserves a position before capture, prepares and admits the complete
value, and returns its `RecordIdentity`:

```swift
let identity = try lease.record(
    capturing: { value },
    preparation: valuePolicy)
```

Use `beginRecord(preparation:capturing:freeze:)` when capture continues over
time, such as HTTP operations and location sessions. It reserves a position
before the complete record exists and returns the system's accumulator:

```swift
let draft = try lease.beginRecord(
    preparation: operationPolicy,
    capturing: { identity in
        try DomainDraft(identity: identity, preparedInput: capturePreparedInput())
    },
    freeze: { draft in draft.freeze() })
```

`DomainDraft` and its record are system types, not Core protocols. Capture time
comes from the system preparation context's `time` service. Core has no phase,
subscription, response, or terminal model that the draft must instantiate.

Execution finalization invokes the supplied freeze closure; there is no separate
`endRecord()` operation. Both recording paths contribute to the same ordered track.

The factory runs after the record position is reserved and outside the lease
state lock. A nested or slower factory cannot move the reserved position. A
factory failure invalidates the candidate; it must clean up any resources it
acquired before throwing. Only record mode accepts the operation.

The freeze callback must synchronize with observations, reject future changes,
release runtime resources, and return a strict already-prepared value. Return
nil if an observed conversion is unfinished or failed. An intentionally open
operation returns an explicit open value in the domain model, not nil. Core
validates the complete value without applying capture transformations again.
A domain must prepare every observation before it enters the working record.

Core freezes every successfully constructed draft exactly once. If construction
returns after execution admission has closed, Core freezes it for cleanup,
discards the value, and reports closed use. The incomplete reservation has
already invalidated the frozen candidate. Escaped drafts must detach their own
content and time/native references; Core releases its callback captures at
closure. Finalization never waits for arbitrary application decisions or slow
capture. Freeze/validation callbacks must not wait synchronously for finish.

The domain owns transition validity, within-record observation order, correlation,
late calls, and diagnostics for incompatible phases. Its implementation must
check admission and synchronize against freeze. The public lease's `isClosed`
provides the admission check; a domain can also use its existing execution
services. Core cannot prove an opaque draft follows this contract.

## Timing and delivery

A system uses `ExecutionTime` to derive local recording delays and current
replay anchors. For HTTP, capture the current decision completion and schedule
its continuation at `logicalTime(after: delay, from: currentDecision)`. Never
reuse an invocation deadline that includes the recorded application's wait.
Location independently accumulates successive delivery delays and preserves
measurement timestamps. The monotonic clock schedules sleeps without recording
a lifecycle.

Core's scheduler owns deadline ordering, non-reentrant registration, atomic
cancellation, delivery acknowledgement, and execution shutdown. The system
owns which continuation is reachable and its callback state. Each domain must
prove its cancellation and freeze behavior together with these services before
native adapters depend on it.
