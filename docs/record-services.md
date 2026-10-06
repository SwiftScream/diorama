# Typed record services

This guide describes the shared services established by
[accepted Decision 19](design-decisions/19-system-owned-records.md). It
replaces the historical [grouped lifecycle API](grouped-lifecycle-recording.md).
The owning system defines its strict record value and runtime lifecycle.

## Record ownership

A `SequentialTrack<Value, Header>` supplies stable identities and ordering for
any `Sendable` value. `Sequential` describes stored order and supports the
simple `consumeNext` operation; it does not require matched operations to arrive
in recorded order. The same claimed-record ledger serves both operations.

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

## Record selection

A selector operates on prepared values and returns equivalent candidates,
no match, or ambiguity. It is pure, deterministic, and does not call live
services. All baseline records are supplied, including claimed records, so
exhaustion can be distinguished from absence.

```swift
let selector = ReplaySelector<String, Operation>.exactInput(\.requestKey)
let claim = try lease.claim(matching: preparedKey, using: selector)
let operation = claim.record.value
```

The selector runs outside lease isolation. Core validates its identifiers and
atomically chooses the earliest still-available equivalent record in stable
sequence order. Empty/duplicate/foreign/unknown identifiers are invalid.
Unresolved ambiguity, exhaustion, and no match are distinct safe diagnostics.
The failure path can use the selector's setup-authored field labels for safe
differences. Record payloads and arbitrary error descriptions are not rendered.

`ReplaySelector<Void, Value>.sequential()` supports the same claim API without
matching an input. `consumeNext()` remains the small synchronous path used by
random and wall observations. Neither path returns a claimed record to the
available pool, even when later replay is canceled or fails.

## Claiming and consuming

A claim reserves one record exclusively and starts unconsumed. The system
acknowledges consumption after replaying all the behavior the record provides:

```swift
let claim = try lease.claim(matching: request, using: httpSelector)
claim.advance(to: deliveredStepCount)
claim.markConsumed() // After replay reaches the end of the recorded behavior.
```

`markConsumed()` reports work already performed; it does not deliver events or
terminate the simulated operation. A record with an open horizon must replay
its observations and reach that horizon before acknowledgement. The operation
can remain open afterward. Core needs no terminal/open projection and cannot
infer consumption from an empty scheduler queue or a progress count.

`consumeNext()` combines claiming and consumption atomically for ordinary values
whose replay consists of returning the value. Both APIs share availability and
appear in `claimedRecords`; synchronous consumption has a progress count of zero.
Explicit claims require acknowledgement even when their values are scalars.

Progress is monotonic. Consumption prevents further progress updates and is
idempotent until the lease closes. Admission closure stops new claims while
in-flight replay can still acknowledge consumption during quiescence; lease
closure freezes the report and rejects further updates. Cancellation or
abandonment neither releases a claim nor automatically marks it consumed.

Two independent opt-in evaluations use these facts:

- `allRecordsClaimed`: every record was claimed, except for attachments whose
  `allowsUnclaimedReplayRecords` policy permits leftovers.
- `allClaimedRecordsConsumed`: every claimed record was fully replayed. The
  leftover policy does not waive this check, and open records receive no exemption.

Unclaimed records do not fail the second check; evaluate both to require every
record to be selected and fully replayed. Neither check runs implicitly or
changes a test outcome. Reports retain safe identities, progress counts, and
`isConsumed` facts, never domain payloads. Systems determine when all recorded
behavior has been replayed; Core cannot verify an opaque lifecycle's semantics.

### Synchronous replay values and continuation

`SequentialTrackLease<Value, Header>` returns its stored `Value` from
`consumeNext()`. Systems translate those values into domain objects, using
execution context where needed. Record types need no mapping protocol, and
Core retains no conversion closure or separate replay representation.
Lease preparation selects a `ReplayContinuationPolicy<Value>`, defaulting
to `.error`:

```swift
let lease = try context.lease(
    for: trackID,
    preparation: ValuePreparation<OverridableValue<Date>>(),
    continuationPolicy: .replayLast(defaultValue: .observed(Date(timeIntervalSince1970: 0))))
let value: OverridableValue<Date> = try lease.consumeNext()
let date: Date = value.value
```

Authorship remains available in returned values and intact for persistence
and re-recording. The wall clock unwraps it when returning a `Date` to its
consumer. Continuation uses the same stored type: the empty-track default above
is an observed value, but it is never added to the track. Explicit selectors
and claims still expose stored records and their identities.

The policy is fixed at lease creation:

| Policy | Exhausted or closed synchronous replay read |
| --- | --- |
| `.error` (default) | Report the failure and throw; retain no continuation value. |
| `.fallback(value)` | Report the failure and return the configured value. |
| `.replayLast(defaultValue:)` | Report the failure and return the most recently consumed stored value, or the default before any synchronous consumption. |

Returning a continuation creates no record, identity, or consumption fact.
Exhausted requests still receive distinct requested positions in diagnostics.
Wrong-mode calls always throw. Explicit claims neither apply nor update the
synchronous continuation policy. The method remains throwing because policy
selection occurs at runtime.

Consumption and continuation updates share one atomic order. Failure selects
its continuation in that same order, then reports outside the lock before
returning. Reentrant diagnostics cannot change the already-selected result.
Closure releases the baseline records. Only replay leases configured for
continuation retain their required fallback value;
`replayLast` releases its default once the first consumption replaces it.
Supplied continuation values must be safe stable values suitable for this
post-finish lifetime, without live resources or execution references.

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
