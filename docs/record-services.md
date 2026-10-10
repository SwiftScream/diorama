# Typed system authoring and record services

[Decision 20](design-decisions/20-system-definitions-and-pure-passthrough.md)
establishes `SystemDefinition` as the public system-authoring boundary.
[Decision 19](design-decisions/19-system-owned-records.md) leaves strict records
and domain lifecycle interpretation with each system. Stable values require
`Sendable`, not `Codable`; optional persistence stays on `ScenarioSystemType`.

## Definitions and typed declarations

A definition supplies one application-facing `Dependency: Sendable` and separate
`RecordState` and `ReplayState` types. Dependencies can be protocol existentials,
ordinary structs, or concrete native classes. Core does not require a dependency
protocol or base class. Application setup constructs a reusable instance with:

```swift
let system = try ScenarioSystem(named: "service", definition: MySystemDefinition())
```

Store typed declarations on the definition. Core derives the attachment layout,
prepares their policies, and retrieves the authoritative loaded content before
activation. For example, a definition may store:

```swift
let values = SystemTrack<UInt64, Void>("values")
var tracks: [AnySystemTrack] { [values.erased] }

func makeReplayState(in context: borrowing SystemStateContext) throws
    -> HeaderlessSequentialTrackLease<UInt64>
{
    try context.lease(for: values)
}
```

Headered declarations accept a `PreparedValue<Header>`, optional initial values,
header/value admission policies, and a typed recording merge. Duplicate keys
fail setup. Copies of a declaration preserve its private identity; a newly
constructed declaration with the same string is foreign. Erasure and typed
recovery stay inside Core. Reusing a definition across keyed instances or runs
never shares their mutable state or cursors.

`validate(in:)` receives a borrowed, noncopyable `SystemValidationContext`.
`context.track(declaration)` reads the resolved prepared header and complete
ordered values without claims, consumption, or capture transformations.
`context.validate(declaration, using:)` wraps domain validation with safe
track-context failure reporting. Every system validates before any state or
dependency factory runs. Passthrough permits setup/native configuration checks
but has no track content or leases to inspect. Persisted decoding stays strict
regardless of the selected mode.

The borrowed `SystemStateContext` provides the same read-only content, repeated
lookup of the already-created lease, and execution time, clock, and scheduling
services. Repeated lookup performs no new admission or transformation. These
contexts cannot be stored or returned. Stable reference values and factory
captures still require ownership discipline: noncopyability does not prove
that arbitrary reference aliases are harmless.

## Managed state and dependencies

Core calls the selected state factory, creates `SystemRuntime<State>`, then
calls the mode's dependency factory. State factories must unwind their own
partial construction if they throw. If dependency construction throws after
state creation, Core invokes that state's cleanup. Completed activations unwind
in reverse order; cleanup failures remain safe diagnostics.

Record and replay dependencies implement their application protocol directly
through `runtime.withActiveState`. The closure receives the entire mutable
state and a noncopyable `inout SystemOperation<State>` token. Core admits and
serializes the operation, retains diagnostic facts, commits state and snapshots
on both successful and throwing exits, unlocks, and then delivers notifications.
A sink can reenter and observe the committed state. A throwing sink adds a
retained `sinkFailed` fact without recursive notification.

Protected closures, source calls, conversion policies, and snapshot projections
must not reenter the runtime, suspend, wait for finish, invoke arbitrary
callbacks, launch untracked work, or expose active-resource aliases. Swift
rejects escaping inout references and operation tokens; copied reference
aliases remain the author's responsibility. Publish native actions with
`operation.afterCommit`, or perform them outside protection. Async delivery
belongs in the scheduler's awaited delivery scope. Registration inside a
protected operation fails with `scheduling(protectedOperation)` before work
starts. Cancellation detaches pending callback captures for release outside
protection, including destructors that reenter a dependency.

A pure `runtime.snapshot { state in ... }` projection is registered during
dependency construction. It updates before each unlock, including throwing
operations and incremental freeze. At closure, Core releases projections and
active state outside protection; retained snapshots hold only their detached
values. A snapshot must not contain a live source, callback, lease, or other
active-resource alias. Systems own continuation policy: Date keeps its last
native or replayed Date in state and a snapshot, beginning at the Unix epoch;
Random returns zero after diagnosed exhaustion or closure.

`cleanUpRecordState` and `cleanUpReplayState` receive detached state outside
protection, exactly once. The default uses ordinary Swift release. Explicit
cleanup may throw safe reported failure. The current hooks are synchronous and
nonisolated; they do not by themselves establish actor-owned native construction
or awaited native shutdown. Those requirements need the separate actor/native
lifecycle evidence. Do not substitute fire-and-forget cleanup.

Passthrough calls only `makePassthroughDependency()`. It has no mode state,
runtime, track lease, interception, continuation, or scenario-owned cancellation.
Native dependencies retain their ordinary copy, concurrency, and lifetime rules,
including after finish. Core drops its references; the consumer owns cleanup.

## Immediate and incremental recording

Reserve before capture so source order and record order agree:

```swift
try runtime.withActiveState { state, operation in
    try operation.record(on: state.values,
                         capturing: { state.source.next() },
                         preparation: valuePolicy)
}
```

A nonthrowing native facade can retain the source return separately when a late
admission or conversion failure prevents recording. The Random and Date
implementations demonstrate that rule explicitly. Failed reservations remain
accounted for and cannot be reused.

For incremental capture, keep the domain's drafts in managed state. The scoped
operation reserves a record before creating a domain identifier or accumulator:

```swift
let identity = try runtime.withActiveState { state, operation in
    try operation.beginRecord(
        on: state.records, preparation: recordPolicy,
        capturing: { identity in
            state.drafts[identity] = try capturePreparedDraft()
            return identity
        },
        freeze: { state, identity in
            state.drafts.removeValue(forKey: identity)?.strictRecord()
        })
}
```

Observation facades retain a runtime and stable identifier, then update the
corresponding draft through `withActiveState`. Capture observation time before
slow conversion; prepare detached semantic data before committing it. Concurrent
conversion can finish in another order, so the domain preserves observation
order and derives delays from the original captures. Native/application work
outside an admitted protected operation remains outside Core's join.

Freeze receives protected mode state exactly once for each successfully created
accumulator. It runs after admitted operations and notifications drain, before
active state detaches. If capture races admission closure, Core defers that
record's cleanup freeze until the current operation unlocks, discards its value,
and diagnoses the incomplete reservation. This never reacquires a held state
lock. Late observations are rejected. Freeze must not wait for finish or an
application decision.

Return a strict, already-prepared domain value. An intentionally open horizon
is an explicit domain value; unfinished or failed conversion returns nil and
invalidates the candidate. Core validates the result without repeating capture
transformations. It has no subscription, response, terminal, or phase model.
The [timed consumer](../Tests/DioramaConsumerTestSupport/ConsumerTimedSystem.swift)
and [recursive operation proof](../Tests/DioramaConsumerTests/SystemOwnedRecordTests.swift)
exercise this boundary with ordinary public imports and no consumer state locks.

## Recording merge

Declare a `RecordingMerge<Value, Header>` on `SystemTrack`. It receives validated
baseline and fresh immutable tracks of the same type and identity, including
headers. A fresh recording can be empty. The callback owns correspondence,
override preservation, deletion, and complete domain validation; Date uses
positions, but Core imposes no correspondence policy.

Healthy record-mode finish invokes a configured merge once after scheduling,
managed operations, and record freeze. It runs outside lease/state locks, uses
only stable values, remains deterministic, and never reads a live source or
waits for recursive finish. Replay, passthrough, unhealthy capture, and startup
rollback do not invoke it. Without a merge, fresh content replaces the track.

Core checks the result's identity and validates its header and values without
rerunning capture transformations. A thrown merge or changed identity reports
`recordingMergeFailed`; validation retains its usual evidence. Either failure
invalidates the candidate and prevents file replacement. Native returns are
unaffected. Usage describes this run's observations, independently of merged
content. Closure releases baseline content and policy/callback captures.

## Selection, claims, and consumption

A selector examines prepared records, including claimed ones, and returns
equivalent identities, no match, or ambiguity. It is pure and deterministic,
uses no live services, and runs within the protected system operation:

```swift
let claim = try runtime.withActiveState { state, operation in
    try operation.claim(on: state.records, matching: preparedRequest,
                        using: ReplaySelector<String, RequestRecord>.exactInput(\.requestKey))
}
```

Core validates identities and claims the earliest available equivalent record
in stored order. Empty, duplicate, foreign, and unknown identities are invalid.
No match, exhaustion, and ambiguity produce distinct safe diagnostics; optional
difference labels contain setup-authored fields, never payloads or error text.
`ReplaySelector<Void, Value>.sequential()` supports selection without an input.

A claim starts unconsumed. Outside protection, deliver the domain behavior and
acknowledge progress with `claim.advance(to:)` and `claim.markConsumed()`.
Acknowledgement reports work already performed; it does not deliver anything or
terminate an operation. Open recordings must reach their recorded horizon and
may remain open afterward. Cancellation never returns a record to availability.
Core cannot infer domain consumption from an empty scheduler or progress count.

`operation.consumeNext(on:)` combines claim and consumption for synchronous
values. Explicit claims require acknowledgement even for scalar records. Both
paths share availability and usage accounting. Consumption is idempotent until
lease closure and prevents further progress updates. New claims stop at
admission closure; in-flight delivery can still acknowledge its claim during
scheduler drainage, before lease closure freezes usage.

Two independent opt-in evaluations remain:

- `allRecordsClaimed` requires every record to be claimed, unless the attachment
  allows unclaimed replay records.
- `allClaimedRecordsConsumed` requires every claimed record to be fully replayed;
  leftover policy and open horizons provide no exemption.

Reports retain safe identities, progress, and consumption facts, never payloads.
Diorama does not decide whether a test passes.

## Execution services and finish

`SystemRuntime.time` and `operation.time` share execution logical time. The
runtime also exposes the execution clock and attachment scheduling lease. Register
reachable replay work outside protection after committing its control state.
Await actor/queue delivery inside the scheduling closure, and acknowledge the
claim after actual delivery. Actor isolation alone does not order independent
equal-deadline tasks; domains establish their own causal sequence.

For decision-relative behavior, capture the current decision and use
`logicalTime(after:from:)`; do not replay an earlier invocation deadline that
includes recorded application wait time. Each execution has one monotonic origin
and rate, while later executions have independent timing and mutable state.

Finish closes admission, cancels pending scheduling, joins claimed deliveries
and admitted state operations including their effects, freezes records, merges
healthy recordings, detaches state, performs reverse cleanup, and freezes the
report. Repeated or canceled finish waiters still await the same owned result.
Finish does not wait for arbitrary consumer work. Calls after closure can add
separate diagnostics but cannot mutate frozen results or read detached sources.

The former closure-based `ScenarioSystem` constructor, `PreparedSystem`,
`ActivatedSystem`, `SystemPreparationContext`, raw lease mutations, and generic
lease continuation policies are internal. Public code uses typed definitions,
scoped operations, and system-owned snapshot continuation. Canonical test runs
compile a positive external definition and reject illegal context/token/state
captures and old-surface access without compiler crashes.
