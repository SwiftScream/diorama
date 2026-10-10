# 003-Fa02: System definitions and Core-managed state

- Date: 2026-10-12
- Status: Complete.
- Plan: [003-Fa02](../plans/003-clean-slate-implementation.md#003-fa02--systemdefinition-and-core-owned-managed-state)
- Authority: DD20 and its recording-lifetime amendment, DD05's final-report-only
  amendment, the Fa handoff, and the owner's instruction to revise Fa02 on the
  merged Fa09 baseline using this session's current model/settings.

## Public boundary

`SystemDefinition` is the sole public authoring path. Typed `TrackDefinition`
values derive keyed layout and carry prepared initial content, header and
value policies, replay continuation, and optional merge. One definition per
track key is permitted within an attachment. Prepared lookup uses the key and
expected value/header types, including for reconstructed declarations. The
registered definition supplies initial content and policies. Core's heterogeneous
registry performs typed recovery; unknown keys and incompatible types fail.
Instances and executions share no mutable cursors.

`AnyTrackDefinition` erases definitions at the layout boundary. The internal
`PreparedTrackRegistry` stores `PreparedTrackEntry` protocol values whose primary
associated types tie both content and lease to the same value/header types.
`PreparedTrack` supplies those properties; lookup recovers a constrained protocol
value rather than the concrete storage type.

Core admits resolved baseline content, then calls optional read-only validation
before any activation. Borrowed noncopyable validation and state contexts expose
stable typed content. State factories repeatedly retrieve the same prepared lease
without repeating policies. Separate record/replay state and dependency factories
preserve typed dependency inference. Dependency factories receive a
`SystemExecution<State>` owning one attachment's mode state and services for
the current scenario run.
Passthrough creates only the native dependency and preserves Fa01's ownership
and copy semantics.

The old constructor, `PreparedSystem`, `ActivatedSystem`,
`SystemPreparationContext`, and raw recording/selection mutations are internal.
Direct sequential `consumeNext()` and `ReplayContinuationPolicy` remain public.
Consumer, persistence, facade, Random, and Date authoring proofs use the new
boundary without gaining `@testable` imports. Low-level Core tests retain internal
access. Persistence registration, schemas, platform floors, and dependencies do
not change.

## Managed concurrency and diagnostics

Core admits and serializes each synchronous whole-state operation with an
`inout` noncopyable operation token. Throwing operations commit state and retain
their diagnostic facts. Fa09's `DiagnosticReporter` is unchanged: reporting calls
no consumer code, `report` is nil until frozen, and later facts enter a separate
post-finish log. There is no diagnostic notification buffer, delivery phase,
notification join, or replacement sink.

The `PostUnlockActions` buffer has non-diagnostic responsibilities:
`afterCommit` work, cancellation-capture release, continuation-value destruction,
and cleanup freeze when incremental registration loses admission. These actions
run after state unlocks. Captures are released before the next effect runs, so
reentrant destruction observes committed state. `OperationTracker` counts
admitted managed operations and direct replay reads so finalization can wait
for their completion, including deferred actions. These helpers live in
separate files and do not change the public API.

Finish closes global admission, joins scheduled delivery and admitted managed
operations and direct replay reads, then freezes records and reports. The direct
read join includes safe fact retention and continuation destruction; it does not
wait for diagnostic consumers. New calls after closure cannot extend the join.
Concurrent or canceled finish waiters still await the execution-owned result.
Claims can acknowledge consumption while scheduled delivery drains.

Incremental freeze accesses the same managed domain state once, after admitted
operations drain and before state detaches. A capture that loses admission after
reserving a record defers its cleanup freeze until the operation unlocks, avoiding
reacquisition of a held lock. Incomplete conversion invalidates the candidate.
Scheduling registration under state protection fails before creating work;
register outside protection or through `afterCommit`.

Core detaches state under protection, releases it, and invokes cleanup outside
protection. Dependency-construction failure cleans its created state; completed
activations unwind in reverse order. Cleanup failures retain safe diagnostics.
Factories that throw before returning state must unwind partial construction.

## Recording lifetime and replay continuation

Recording Random and Date use explicit dependency structs and `withActiveState`.
They reserve before capture, preserve native results on late recording failure,
and retain their live source separately from managed state. Calls after closure
diagnose and read that same source exactly once without recording. Random copies
share a serialized source. Releasing the last dependency releases its source.

Replay dependencies call the sequential lease directly. Date selects replay-last
with an observed Unix-epoch default; Random selects zero fallback. Error
continuation is also available. Replay constructs no live source. No
`SystemRuntime.snapshot()`, `SystemSnapshot`, or projection registration remains.
Location and URLSession keep their separately specified shutdown requirements.

## Migration and regression evidence

The Date conversion-failure tests preserve unsupported native returns, source
order, candidate invalidation, final-report facts, and subsequent live reads.
The Random regression gates a reserved source read, observes admission closing,
and proves finish waits before releasing it. It retains the live result and
incomplete-record facts, handles a canceled finish waiter, and permits an
unrecorded live read afterward. Admission probing deliberately contributes one
`executionClosed` fact. Bounded gates prevent a failed assertion from stranding
the runner. Source lifetime tests release retained recording dependencies and
check actual source destruction.

Public replay tests exercise every continuation policy after managed closure,
unused-record accounting, final-report-only exhaustion facts, and immutable
results. A controlled Core test blocks reference-valued continuation destruction
during a direct read: finish waits, and the destructor's fact reaches the final
report. Other tests prove destruction occurs outside lease and system execution locks.

Public consumer proofs cover non-Codable values, keyed mixed modes, persistence,
merge, time, clock, scheduling, actor delivery, exclusive selection, claims,
consumption, recursive/open records, and managed incremental drafts. Additional
proofs cover typed validation, duplicate and unknown keys, incompatible lookup
types, repeated lookup, fresh executions, no activation after validation failure,
throwing operations, reverse rollback, cleanup failure, cancellation reentry,
late freeze registration, and failed construction releasing callbacks and closing
escaped scheduling.

Fa09A's admission and retained-report tests now use public `SystemDefinition`
fixtures. They retain coverage for overlapping/nested rejection, sequential reuse,
cancellation through cleanup, startup rollback, original body errors, immutable
retained reports, and release of dependencies and error captures.

## Verification and commit structure

Initial verification on the Fa09-based revision passed:

- `scripts/check`: 416 macOS tests, strict formatting/lint, warnings-as-errors
  compilation, release builds, and both examples.
- `scripts/coverage swiftpm macos`: 416 tests, public API probes, release/example
  checks, and LCOV export. Coverage includes 4,968 of 5,062 executable lines
  across 61 source files.
- `scripts/coverage ios`: release compilation with the iOS 18 deployment target,
  415 applicable tests on iPhone 17 / iOS 27.0, and LCOV export with the same
  4,968 of 5,062 executable lines across 61 files.
- `scripts/coverage swiftpm linux`: 416 tests, public API probes, release builds,
  both examples, and LCOV export in the approved Swift 6.4 Ubuntu x86_64 image
  (`64bab762bc73`), with two CPUs and 4 GB through Apple Container. Existing
  emulation-launcher signal 32/33 notices remain; compiler warnings still fail.
- The compiler probes pass one external definition and require ordinary rejection
  for nine context/token/state escape and retired-API cases, without crashes.
- All 204 package/source/test/example/script inputs match the isolated iOS copy.
  Reordering integration corrections into their owning commits preserves the
  verified tree exactly. All 337 checked local documentation link targets resolve;
  `git diff --check` and the complete branch diff against master pass.

Apple checks use Swift 6.4 / Xcode 27.0. These local results precede the review
update below; required PR checks additionally run the platform matrix,
URLSession spike gates, and Codecov uploads. Earlier Fa02 runs predate this
integration.

At the owner's request, the implementation and its review corrections are
consolidated into one code commit. The final branch has two commits:

1. Managed system authoring: typed definitions, Core-owned state, scoped
   operations, direct replay reads, deferred actions, incremental freeze,
   Random/Date and public-consumer migration, lifecycle regression tests,
   legacy-surface retirement, compiler probes, and authoring documentation.
2. Plan, schema and service guidance, and this conformance evidence.

### Review update — 2026-10-13

At the owner's request, remove the `legacy-authoring` and
`legacy-preparation-context` compiler probes. The remaining seven negative
probes cover scoped context/token/state escapes and raw track mutation; the
positive external definition remains. Update the plan and quality gate to match.

macOS `scripts/check` passes all 416 tests, formatting, strict lint, one positive
and seven negative compiler probes, release builds, and both examples.
`bash -n scripts/tests/system-authoring` and `git diff --check` also pass.
The owner defers the iOS/Linux matrix until the review is ready.

### Internal naming review — 2026-10-13

Split the internal helpers into `PostUnlockActions.swift` and
`OperationTracker.swift`. Use `drain()` for deferred actions and
`closeAdmission()` / `waitUntilIdle()` for operation tracking. Update call sites,
the existing lifetime test, and comments without changing behavior or public API.

macOS `scripts/check` passes all 416 tests, formatting, strict lint, one positive
and seven negative compiler probes, release builds, and both examples.
`git diff --check` passes. The iOS/Linux matrix remains deferred by the owner.

### Track key lookup review — 2026-10-14

At the owner's request, replace private declaration identity with track-key
lookup scoped to one attachment and execution. Existing attachment construction
rejects duplicate keys before preparation, including separate definitions with
different value/header types. Unknown keys and incompatible lookup types retain
the safe `invalidTrackRequest` diagnostic.

Public consumer tests prove reconstructed same-key lookup in validation and
state contexts, repeated lookup of the same lease, registered initial content
and policy authority, resolved loaded content, and independent keyed instances
and executions. Additional cases exercise duplicate registration and invalid
lookup during both validation and activation. No persistence schema changes.

The focused authoring suites pass 13 macOS tests. macOS `scripts/check` passes
all 419 tests, formatting, strict lint, one positive and seven negative compiler
probes, release builds, and both examples. `git diff --check` passes. The
iOS/Linux matrix remains deferred by the owner.

### Track naming and prepared-entry protocol review — 2026-10-14

Rename `SystemTrack` to `TrackDefinition`, `AnySystemTrack` to
`AnyTrackDefinition`, `PreparedSystemTrack` to `PreparedTrack`, and
`SystemTrackRegistry` to `PreparedTrackRegistry`. Update production systems,
consumer fixtures, compiler probes, guides, and the lookup test suite. The
definition, prepared pair, and registry live in separately named source files.

Replace the registry's broad `any Sendable` storage with `any PreparedTrackEntry`.
The protocol declares primary associated value/header types and requires the
matching lease and content properties. Preparation returns protocol entries,
and lookup recovers a constrained protocol value. Key validation, policy
authority, per-execution ownership, and persistence schemas remain unchanged.

The existing focused authoring suites pass 13 macOS tests, including same-key
lookup, duplicate registration, and incompatible-type rejection. macOS
`scripts/check` passes all 419 tests, formatting, strict lint, one positive and
seven negative compiler probes, release builds, and both examples.
`bash -n scripts/tests/system-authoring` and `git diff --check` pass. The
iOS/Linux matrix remains deferred by the owner.

### System execution naming review — 2026-10-14

Rename `SystemRuntime<State>` to `SystemExecution<State>` and its source file to
`SystemExecution.swift`. Rename corresponding parameters, properties, and local
bindings to `execution` throughout Core, Random, Date, consumer fixtures, and
compiler probes. Update current guides and plan guidance; retain Decision 20's
historical wording with an explicit owner-approved naming note.

The Swift implementation and test changes are identifier renames only; state
ownership, operation admission, deferred actions, and finalization are unchanged.
The existing focused authoring suites pass 13 macOS tests. macOS `scripts/check`
passes all 419 tests, formatting, strict lint, one positive and seven negative
compiler probes, release builds, and both examples.
`bash -n scripts/tests/system-authoring` and `git diff --check` pass. The
iOS/Linux matrix remains deferred by the owner.

## Limits

Protected operations and source/conversion calls cannot suspend, reenter through
unadapted services, wait for finish, invoke arbitrary callbacks, launch untracked
work, or return arbitrary active-resource aliases. Compiler probes reject illegal
context/token/state escapes; arbitrary copied reference aliases still require
author discipline. A retained closed-safe replay lease is explicitly supported.

Cleanup hooks remain synchronous and nonisolated. Actor-owned native construction
and awaited shutdown require Fa06 and adapter-specific evidence. Generic typed
validation is established here; Date whole-track validation belongs to Fa03.
Local simulator results do not establish minimum-OS runtime coverage. Recording
source retention by escaped dependencies is a deliberate lifetime tradeoff.
