# 003-Fa02: System definitions and Core-managed state

- Date: 2026-10-11
- Status: Complete.
- Plan: [003-Fa02](../plans/003-clean-slate-implementation.md#003-fa02--systemdefinition-and-core-owned-managed-state)
- Authority: DD20, the Fa handoff, and the owner-approved ordered stack using
  this session's current model/settings.

## Public boundary

`SystemDefinition` is the sole public authoring path. Typed `SystemTrack`
declarations derive keyed layout and carry initial prepared content, header/value
policies, replay continuation, and optional merge. Declaration copies preserve identity; a new
same-key declaration is foreign. Core's heterogeneous registry performs typed
recovery. Per-instance, per-execution registries never share mutable cursors.

Core admits resolved baseline content, then calls optional read-only validation
before any activation. Borrowed noncopyable validation and state contexts provide
stable typed content; state factories repeatedly retrieve the same prepared
lease without repeating policies. Separate record/replay state and dependency
factories retain ordinary typed dependency inference. Passthrough creates only
the native dependency and preserves Fa01's ownership and copy semantics.

The old constructor, `PreparedSystem`, `ActivatedSystem`,
`SystemPreparationContext`, and raw recording/selection mutations are internal.
Direct sequential `consumeNext()` and `ReplayContinuationPolicy` remain public. Low-level Core tests retain internal access. All consumer,
persistence, facade, Random, and Date authoring proofs use the replacement;
public-only consumer proofs gain no `@testable` imports. Descriptor-based optional
persistence, schemas, deployment floors, and dependencies do not change.

## Managed concurrency and lifecycle

Core admits each synchronous whole-state operation and serializes it with an
`inout` noncopyable operation token. A scoped effect buffer retains diagnostic
facts immediately while delaying sink notification until after state commits.
Throwing operations also commit state and flush retained notifications. Sink failure remains separately retained.

Finish closes global admission and joins scheduled delivery and admitted state
operations and direct sequential reads, including their notifications and
synchronous published effects,
before freezing records and reports. Calls after closure cannot extend this
join. Canceled or concurrent finish waiters still await the execution-owned
result. Claim acknowledgement remains available during scheduled-delivery drain.

Incremental freeze accesses the same managed domain state once. A capture that
loses admission after reserving a record queues its cleanup freeze until the
current operation unlocks; it does not reacquire a held lock. Normal freeze runs
after the operation join and before state detaches. Domain drafts are stored in
managed state and exposed through runtime/identity facades. Incomplete conversion
invalidates the candidate; it does not force a fabricated domain conclusion.

Scheduling registration under protection fails before creating work. Systems
register outside protection or publish registration with `afterCommit`.
Cancellation remains atomic, but detached callback captures are released after
state unlocks. Effect delivery also releases each callback's captures before
publishing the next effect, so destructor reentry sees committed state.

Closure detaches managed state under protection, then releases it and invokes
mode-specific cleanup outside protection. Recording Date/Random sources belong
to their returned dependencies and survive while those dependencies are retained. Dependency-construction
failure cleans its created state; successful earlier activations unwind in
reverse order. Cleanup failures retain safe diagnostics. Factories that throw
before returning state remain responsible for partial construction cleanup.

Protected closures, source calls within them, and conversions cannot suspend,
reenter through unadapted services, wait for finish, call arbitrary callbacks,
launch untracked work, or return arbitrary active-resource aliases. A replay
dependency may retain its closed-safe sequential lease. Compiler checks reject
illegal inout/context/token escapes; arbitrary copied reference aliases still
require author discipline. This is not an async native lifecycle framework.

## R1 and migration evidence

Random and Date have explicit record/replay dependency structs. Recording uses
`withActiveState`, reserves before capturing, and preserves each native result
on late recording failure. Date captures timezone before its source factory and
keeps conversion progress in managed state. Both recording dependencies retain
the live source separately: closed calls diagnose and read that same source
exactly once without recording. Random copies share one serialized source.

Replay calls the lease directly. Date selects replay-last with an observed
Unix-epoch default; Random selects zero fallback. No runtime snapshots or
projection closures remain. Public-only tests cover all three policies after
finish, immutable results, unused records, and finish joining a direct read's
blocked diagnostic sink. Reference-valued continuation replacement releases
captures outside both lease and enclosing runtime protection.

The Date conversion-failure regression has a diagnostic sink reread the same
wall dependency. It proves unlocked reentry, source order, retained conversion
failure, unchanged unsupported native return, and continued live reads after
finish. The Random regression gates a reserved native read, closes admission,
and gates its reentrant notification. It proves finish waits for notification
completion, preserves the captured result, records incomplete capture, permits
one subsequent live read, and supports a canceled concurrent finish waiter.
Controlled gate guards release after five seconds on failure; passing paths
complete immediately and cancel the guards. Source-release tests prove that
retained recording dependencies own their native lifetime. Concurrent late
Random reads remain serialized and leave the frozen recording empty.

Public consumer proofs cover non-Codable values, keyed mixed modes, persistence,
merge, time, clock, scheduling, actor delivery, exclusive selection, claims,
consumption, recursive/open domain records, and managed incremental drafts.
Additional proofs cover resolved-baseline validation, headered same-value tracks,
duplicate/foreign declarations, copied and repeated lookup, validation-only
admission, fresh executions, zero activation after later validation failure,
throwing operations/sinks, committed-state visibility, reverse rollback, cleanup failure,
callback/cancellation destructor reentry, late freeze registration, and failed
construction releasing callback captures and closing escaped scheduling.

One old mismatch-construction assertion becomes derived-identity validation:
the public constructor no longer accepts a separately supplied attachment/type.
Compiler probes reject that former surface. A typed-layout failure now precedes
that system's optional validation hook; the facade test checks the exact failing
track and zero activation instead of expecting the old preparation callback.
These are consequences of Core deriving/preparing layout, not relaxed admission.

## Verification and commit structure

The initial verification below predates the recording-lifetime review. The
review's fresh verification is recorded separately at the end of this document.

Apple Swift 6.4 / Xcode 27.0 passes `scripts/check`: 405 tests, strict formatting
and lint, warnings-as-errors compilation, release builds, and both examples.
Canonical `scripts/test` also compiles one positive external definition and
requires ordinary rejection for nine context/token/state escape and retired-API
probes. None crashes the compiler. The probes inspect actual compiled public
module access, not source text.

An isolated snapshot passes `scripts/coverage ios`: iOS 18 deployment-target
release compilation, 404 tests on iPhone 17 / iOS 27.0, and current-build LCOV
export. The approved pinned Swift 6.4 Ubuntu x86_64 image with two CPUs and
4 GB passes `scripts/test --enable-code-coverage`: 405 tests, the positive and
nine negative compiler probes, release builds, and both examples. This run
reuses the task-owned Linux build cache after replacing source inputs. The
existing emulation launcher notices for signals 32/33 do not change the
warnings-as-errors compiler policy. All 261 checked local documentation link
targets resolve, and `git diff --check` passes.

Implementation commits, in order:

1. Typed definitions, managed state, scoped operations, diagnostic
   buffering, joins, and initial public proofs.
2. Random/Date migration and the two R1 regressions.
3. Deferred effects, cancellation release, managed incremental time,
   sequential/persistent consumer migrations, and race/rollback proofs.
4. Complete public-consumer migration, legacy-surface retirement,
   compiler probes, and public contract documentation.

Generic whole-track validation is established here. Fa03 separately wires Date's
strict whole-track interpretation to close R2. Native actor construction and
awaited cleanup are not established by these synchronous factories/hooks; Fa06
investigates that public boundary before native adapter work. Required PR checks
cover formatting/lint, macOS/iOS/Linux execution, and Codecov uploads. The local
runs above do not establish minimum-platform runtime coverage.

Final stack review catches and corrects an integration between these probes and
Fa07's isolated coverage builds. `scripts/test` queries the product path using
the same test arguments and passes it to the compiler-probe runner. The runner
therefore uses the tested scratch path and configuration. An isolated checkout
without default build products reproduces the former `no such module
'DioramaCore'` failure; the corrected runner passes the positive and all nine
negative probes using the supplied product path.

Fresh macOS coverage on the completed production stack passes 410 tests, all
probes, release/example builds, and LCOV export: 4,990 of 5,080 executable lines
across 61 source files. Its log confirms that the probes read the invocation's
private build products. The source-line total is for the final stack including
Fa03, rather than Fa02 in isolation.
The same fresh coverage command on pinned Linux passes 410 tests, all probes,
release/example builds, and exports 4,989 of 5,080 lines across 61 files. Both
exports use repository-relative paths. A final `scripts/check` also passes
410 tests and all canonical host checks with the default build path.

For the isolated Fa02 PR, the five Fa02 commits are cherry-picked onto the
integrated Fa01 baseline with no implementation changes. Fresh focused checks
pass all 12 managed-definition and Random/Date diagnostic-reentry tests.
`scripts/check` passes all 405 tests, strict formatting/lint, the positive and
nine negative compiler probes, release builds, and both examples. All 257 local
link targets in the changed Markdown documents resolve, and
`git diff --check origin/master` passes across the complete Fa02 change.

## Recording-lifetime review — 2026-10-11

The owner approves system-defined recording behavior after closure and removal
of `SystemRuntime.snapshot()` / `SystemSnapshot`. The
[DD20 amendment](../design-decisions/20-system-definitions-and-pure-passthrough.md#recording-lifetime-and-replay-continuation-amendment--2026-10-11)
records the contract and preserves Location/URLSession shutdown. Review changes
remain unsquashed adjacent fixups: the core boundary, Random/Date migration,
incremental consumer instrumentation, public-surface/documentation migration,
and this evidence. Existing review fixups remain separate.

Fresh checks for the Fa02 review revision pass:

- macOS `scripts/check`: 408 tests, formatting, strict lint, warnings-as-errors
  compilation, one positive and nine negative public API probes, release builds,
  and both examples. The positive probe exercises the public continuation policy
  and direct lease read; raw recording mutation remains inaccessible.
- `scripts/coverage ios`: release compilation with the iOS 18 deployment target,
  407 tests on iPhone 17 / iOS 27.0, and current-build LCOV export.
- `scripts/coverage swiftpm linux`: 408 tests, the public API probes, release
  builds, both examples, and LCOV export using the approved Swift 6.4 Ubuntu
  x86_64 image (`64bab762bc73`), two CPUs, and 4 GB. The existing emulation
  launcher signal 32/33 notices remain; compiler warnings still fail the gate.
- The isolated platform copies match all 200 Fa02 source, test, package,
  example, and script inputs. The restacked Fa03 production code also passes
  `scripts/check`, including all 413 tests and the same compiler/build gates.
- All 356 local link targets in changed Markdown files resolve, and
  `git diff --check` passes.

The tradeoff is deliberate native-source retention by recording dependencies.
Dropping the last retained dependency releases its source; finish releases
managed state and freezes results. Late calls retain diagnostics separately.
These local checks do not constitute hosted CI or minimum-OS runtime evidence.
