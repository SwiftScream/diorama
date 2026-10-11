# Plan 003 Fa01/Fa02 implementation handoff

This is implementation guidance for the approved
[Phase Fa units](003-clean-slate-implementation.md#phase-fa--passthrough-and-system-authoring).
[Decision 20](../design-decisions/20-system-definitions-and-pure-passthrough.md)
is the accepted contract. Start with the current reviewed repository baseline,
follow protocol R, and implement one unit at a time. No exploration checkout,
unmerged commit, temporary directory, or unpublished file is a prerequisite.

## Starting point

At handoff, the integrated implementation includes F01–F07 and the DioramaDate
rename. Its authoring path uses public `PreparedSystem`, `ActivatedSystem`,
`SystemPreparationContext`, and the closure-based `ScenarioSystem` initializer.
The proposed `SystemDefinition`, `SystemRuntime`, typed track declarations,
scoped operation token, and managed diagnostic buffering are not prerequisites
already delivered on that baseline. Fa02 must implement the needed machinery.

Read these implementation areas and their proving tests together:

- [Startup and activation](../../Sources/DioramaCore/ScenarioSystem.swift),
  [preparation](../../Sources/DioramaCore/SystemPreparationContext.swift), and
  [execution/finalization](../../Sources/DioramaCore/ScenarioExecution.swift).
- [Record leases](../../Sources/DioramaCore/SequentialTrackLease.swift) and
  [diagnostic reporting](../../Sources/DioramaCore/DiagnosticReporter.swift).
- [Random](../../Sources/DioramaRandom/DioramaRandomSystem.swift),
  [Date setup](../../Sources/DioramaDate/DioramaDateSystem.swift), and
  [Date dependency](../../Sources/DioramaDate/DioramaDateSource.swift).
- [Consumer-system support](../../Tests/DioramaConsumerTestSupport),
  [external-system tests](../../Tests/DioramaConsumerTests), and the
  [record](../record-services.md), [time](../execution-time-service.md), and
  [scheduling](../execution-scheduling.md) guides.

## Fa01: deliver native passthrough first

Use the existing authoring mechanism for this unit. Do not introduce the
Fa02 protocol or require its implementation as a prerequisite. Make the
smallest internal startup/usage changes necessary to activate passthrough
without preparing or constructing track leases. Preserve immutable loaded
baseline content and ordered passthrough usage facts independently of leases.

For Random and Date, the selected passthrough factory should return its live
source directly. No wrapper should retain a closed flag, continuation value,
reporter, or Core lock for that dependency. Source factories still run once per
selected activation, after preparation; replay never constructs a live source.
Keep setup and optional persistence registration APIs otherwise stable.

Test the intentional differences: live access after finish produces no new
diagnostic; copied value generators advance independently; reference sources
retain native sharing; a retained handle keeps its live source alive. Once
ordinary owners release it, the finished execution must not retain it. A setup
factory may itself deliberately retain a consumer-owned source. Do not call
this a leak solely because the consumer intentionally retains the dependency. Ordinary
native cleanup remains the consumer's responsibility.

Keep loaded passthrough data through mixed-mode re-record. Reject malformed
persisted input at the decoder as before, but prove that record/replay content
policies are not invoked for passthrough. Replay-only executions remain
read-only. Test startup failure after another passthrough dependency has been
constructed, including reference release and factory-owned partial cleanup.

Fa01 changes existing first-party and public consumer proofs only. It does not
build Location or URLSession. DD20 updates their future passthrough contract.

## Fa02: target authoring shape

The following Swift is a design sketch, not a compiled implementation. Names
other than the requested `SystemDefinition` may be refined during the unit.
Its shape incorporates Fa01; it does not reproduce the older experimental
managed-passthrough path.

```swift
public protocol SystemDefinition: Sendable {
    associatedtype Dependency: Sendable
    associatedtype RecordState: Sendable
    associatedtype ReplayState: Sendable

    var systemType: ScenarioSystemType { get }
    var tracks: [AnySystemTrack] { get }

    func validate(in context: borrowing SystemValidationContext) throws
    func makeRecordState(in context: borrowing SystemStateContext) throws -> RecordState
    func makeReplayState(in context: borrowing SystemStateContext) throws -> ReplayState

    func makeRecordDependency(using runtime: SystemRuntime<RecordState>) throws -> Dependency
    func makeReplayDependency(using runtime: SystemRuntime<ReplayState>) throws -> Dependency
    func makePassthroughDependency() throws -> Dependency
}
```

Provide defaults for no tracks and no extra validation. There is no passthrough
state factory, `PassthroughState`, or default `Void` passthrough state to retain.
The validation context identifies the mode; passthrough permits only applicable
setup/native-configuration checks, with no prepared track access or
record/replay-only capability rejection.

Expose `ScenarioSystem(named:definition:allowsUnclaimedReplayRecords:)` as the
public construction path. Keep application-facing `.instance()` conveniences,
typed dependency inference, keyed heterogeneous setup, and descriptor-based
optional persistence. `Dependency` may be an existential or a concrete class.
Do not add a required dependency protocol or subclass.

### Preparation and activation

Store typed track declarations on the definition. For example:

```swift
let values = SystemTrack<UInt64, Void>("values")
var tracks: [AnySystemTrack] { [values.erased] }

func makeRecordState(in context: borrowing SystemStateContext) throws -> RecordState {
    let lease = try context.lease(for: values)
    return RecordState(source: sourceFactory(), values: lease)
}
```

Core uses the declaration for attachment layout, stable key, prepared initial
content, header/value policies, and optional re-record merge. Read-only
validation uses the declaration to retrieve prepared content; state creation
uses it to retrieve the already-created lease. Repeated lookup returns the same
lease without repeating admission, transforms, or consumption.

Fa02 must prove that this hook sees the resolved baseline and that every
system validates before any activation. The follow-up
[Fa03](003-clean-slate-implementation.md#003-fa03--whole-track-date-admission-and-preparation-proof)
uses it to close review finding R2: Date reuses its strict whole-track validator
and rejects malformed headers/values at preparation. Keep generic hook tests
in Fa02; do not defer its own correctness tests to Fa03.

The experiment used a retained private identity token per declaration, with
typed recovery in Core's heterogeneous registry. Copies preserve that identity;
a new declaration with the same string key is not the same declaration. This
is a viable implementation, not permission for unchecked casts in system code.
Reject duplicate keys and undeclared/foreign lookup. Keep registries scoped to
one instance and execution; shared reusable definitions must not share cursors.

Use scoped read-only preparation and activation contexts. The experiment made
them borrowed noncopyable values so they could not be returned or stored. This
does not prevent arbitrary reference aliases from escaping; document those
obligations. Validate every system before activating any. Resolve all track
requirements before constructing live resources. If state/dependency creation
throws, release the state and unwind completed activations in reverse order.

### Core-owned state and the diagnostic deadlock

The original concurrency concern must be fixed in this refactor. A Date or
Random source lock can span a lease operation; conversion/admission failure
then calls a diagnostic sink synchronously. If that sink reads the same
dependency, it attempts to reacquire the source lock and deadlocks. Merely
moving that lock into Core recreates the problem unless notification delivery
also moves outside the protected operation.

The explored solution combined these responsibilities in Core:

1. Admit one synchronous operation and serialize access to the entire mode's
   mutable state, not just reads or live source calls.
2. Supply a noncopyable scoped operation token for recording, selection,
   consumption, and diagnostics. Retain facts immediately in the shared ledger,
   while buffering sink notifications for this operation.
3. Commit managed state before unlocking, including on throwing exits.
4. Unlock before delivering diagnostic notifications, publishing queued work,
   or invoking cancellation handlers. Reentry then sees committed state.
5. Track admitted work/notifications so finish joins them before freezing its
   report. New calls after closure diagnose without extending the finish join.
6. Detach managed state at closure and release it outside the state lock.
   Under the approved 2026-10-11 DD20 amendment, recording dependencies may
   retain their own live source; replay dependencies may retain a closed-safe
   sequential lease with its selected continuation value.

System implementations should not need their own locks or manual notification
flushes for these managed operations. Protected closures cannot reenter Core
through unadapted services, invoke arbitrary callbacks, suspend, wait for
finish, or return arbitrary active-resource aliases. Source and conversion
closures inherit these rules. Native delivery happens outside protection.

Use a nonescaping `inout` operation token if retaining the demonstrated
noncopyable shape. One Swift 6.4 experimental spelling with an explicitly
borrowed closure parameter crashed the compiler; the `inout` form produced
normal diagnostics for illegal escapes. Prove the selected production spelling
with positive and negative compiler checks instead of unsafe annotations.

### Readable Random and Date implementations

Prefer distinct record and replay dependency structs implementing the
application protocol directly. The approved
[DD20 lifetime amendment](../design-decisions/20-system-definitions-and-pure-passthrough.md#recording-lifetime-and-replay-continuation-amendment--2026-10-11)
supersedes the earlier snapshot experiment described in this handoff.

Recording Random keeps its native mutable generator in a shared serialized
source owned by the returned dependency. Managed state contains the UInt64
lease. Reserve through `withActiveState` before reading, preserve a captured
native return if subsequent admission fails, and read the source exactly once
if closure prevents capture. Deliver diagnostics outside both state and native
source protection. Copied dependencies share that source after finish.

Recording Date similarly owns its live source in the returned dependency.
Managed state contains wall-conversion progress and the headered lease. Capture
the recording timezone before constructing the source. Keep conversion and
merge logic shared; preserve the native return on conversion failure. After
closure, return live dates with diagnostics and no new recording.

Replay dependencies retain the sequential lease and call public `consumeNext()`
directly so closure reaches its `ReplayContinuationPolicy`. Random selects
`.fallback(0)`; Date selects `.replayLast(defaultValue: .observed(unixEpoch))`.
Core joins admitted direct reads and their notification delivery. No live
source is constructed for replay. Remove `SystemRuntime.snapshot()` and
`SystemSnapshot`, their projections, and duplicate last-value state.

Pure passthrough continues to return `sourceFactory()` directly, preserving
native copy semantics and undiagnosed live use after finish. Location and
URLSession retain their explicit managed shutdown contracts; any future frozen
property view should use small system-specific stable state.

### Complete the existing extension boundary

Migrate every public-only consumer proof, not just the first-party systems:

| Existing capability | Required migration evidence |
| --- | --- |
| Non-Codable values, repeated keyed systems, mixed modes | Public `SystemDefinition` implementations with independent state and unchanged setup inference. |
| Optional persistence and authored re-record merge | Existing descriptor/codec registration, typed declaration policy, preserved baseline and publication behavior. |
| Execution time, clock, and scheduling | Appropriate scoped services in the new context/runtime; retain delayed handoff, cancellation, state-before-callback, and acknowledgement semantics. |
| Incremental `beginRecord` and freeze | Safe registration/finalization races, one freeze, rejection of late observations, detached resources, and no reacquisition of a held state lock. |
| Selection, exclusive claims, consumption | Scoped Core operations and preserved claim ownership/accounting; no domain lifecycle interpretation added to Core. |
| Diagnostic and cleanup outcomes | Reentrant sinks, thrown operations, sink failure, rollback, cleanup failure reporting, and immutable final reports. |

The prototype did not finish time/scheduler context integration or managed
incremental freeze. Those are existing supported capabilities and must be
completed in Fa02 before hiding the old authoring API. Likewise, intentional
cleanup formerly supplied through `ActivatedSystem.deactivate` needs a supported
replacement, including its reported failures. Do not equate releasing Swift
state with completing every existing cleanup obligation.

Internalize `PreparedSystem`, `ActivatedSystem`, and the old closure-based
initializer if still used by Core. Remove redundant overloads rather than
keeping a second implementation path. Audit related public preparation,
synchronous-state, and operation surfaces for obsolete leaks. Core tests may
use internal access; external-system proofs must keep ordinary imports.

Use controlled tests for live capture racing finish, sink/callback/cancellation
reentry, repeated/concurrent finish, queued work during activation failure,
claim acknowledgement, post-closure recording/replay behavior, and ownership
through escaped handles.
Do not weaken prior assertions simply to make the API migration compile.

### Native follow-up and evidence limits

Complete native lifecycle design is deferred to G08 and I01. A concrete
`Dependency = URLSession` works with two factories returning differently
configured sessions and a bridge routing to the selected runtime. It still
needs explicit native invalidation, routing release, replay callback drainage,
and detached forwarding for already-running live work. A Core state lock must
not surround reentrant native calls. Location similarly needs actor-aware
manager construction and cleanup. Include failed-startup cleanup of native
resources that may retain themselves after the execution drops its references.
Investigate these before substantial adapter
implementation; do not invent a general native framework in Fa02.

[Fa06](003-clean-slate-implementation.md#003-fa06--public-actor-owned-lifecycle-evidence)
adds an isolated public actor-lifecycle proof before Location's facade depends
on this boundary. It records any required follow-up explicitly and does not
replace actual native evidence or authorize a framework redesign.

Historical exploration exercised Random, Date, typed declarations, separate
mode state, an external callback facade, and frozen snapshots. Its final checks
reported 405 tests on macOS and pinned Linux, eight compiler rejection probes,
release/example builds, lint, and iOS test compilation. iOS test execution and
native adapter integration were not established. That experiment retained
managed passthrough and the old public authoring path, so those results do not
verify Fa01 or complete Fa02. The sketches here preserve the useful design
lessons without requiring that implementation to be recovered or promoted.

Each unit must produce its own current V-code evidence under the repository
quality policy. Record completion in Plan 003 and use evidence filenames
`003-Fa01-pure-passthrough.md` and `003-Fa02-system-definitions.md`. Do not claim
historical prototype runs as checks of a new production revision.
