# 003-Fa02: System definitions and Core-managed state

- Date: 2026-10-11
- Status: Complete.
- Plan: [003-Fa02](../plans/003-clean-slate-implementation.md#003-fa02--systemdefinition-and-core-owned-managed-state)
- Authority: DD20, the Fa handoff, and the owner-approved ordered stack using
  this session's current model/settings.

## Public boundary

`SystemDefinition` is the sole public authoring path. Typed `SystemTrack`
declarations derive keyed layout and carry initial prepared content, header/value
policies, and optional merge. Declaration copies preserve identity; a new
same-key declaration is foreign. Core's heterogeneous registry performs typed
recovery. Per-instance, per-execution registries never share mutable cursors.

Core admits resolved baseline content, then calls optional read-only validation
before any activation. Borrowed noncopyable validation and state contexts provide
stable typed content; state factories repeatedly retrieve the same prepared
lease without repeating policies. Separate record/replay state and dependency
factories retain ordinary typed dependency inference. Passthrough creates only
the native dependency and preserves Fa01's ownership and copy semantics.

The old constructor, `PreparedSystem`, `ActivatedSystem`,
`SystemPreparationContext`, raw lease mutations, and generic lease continuation
policies are internal. Low-level Core tests retain internal access. All consumer,
persistence, facade, Random, and Date authoring proofs use the replacement;
public-only consumer proofs gain no `@testable` imports. Descriptor-based optional
persistence, schemas, deployment floors, and dependencies do not change.

## Managed concurrency and lifecycle

Core admits each synchronous whole-state operation and serializes it with an
`inout` noncopyable operation token. A scoped effect buffer retains diagnostic
facts immediately while delaying sink notification until after state and pure
snapshot projections commit. Throwing operations also publish snapshots and
flush retained notifications. Sink failure remains separately retained.

Finish closes global admission and joins scheduled delivery and admitted state
operations, including their notifications and synchronous published effects,
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

Closure detaches state and projection closures under protection, then releases
them and invokes mode-specific cleanup outside it. Dependency-construction
failure cleans its created state; successful earlier activations unwind in
reverse order. Cleanup failures retain safe diagnostics. Factories that throw
before returning state remain responsible for partial construction cleanup.

Protected closures, sources, conversions, and projections cannot suspend,
reenter through unadapted services, wait for finish, call arbitrary callbacks,
launch untracked work, or return active-resource aliases. Compiler checks reject
illegal inout/context/token escapes; arbitrary copied reference aliases still
require author discipline. This is not an async native lifecycle framework.

## R1 and migration evidence

Random and Date have explicit record/replay dependency structs using
`withActiveState` directly. Random preserves a captured native result on late
recording failure. Date captures timezone before its source factory, keeps
recording conversion progress and last native return in one state, and resolves
replay continuation in the same operation as consumption. Detached snapshots
preserve the last Date after closure; both modes begin at Unix epoch.

The Date conversion-failure regression has a diagnostic sink reread the same
wall dependency. It proves unlocked reentry, source order, retained conversion
failure, unchanged unsupported native return, admitted later observations, and
fresh frozen continuation. The Random regression gates a reserved native read,
closes admission, and gates its reentrant notification. It proves finish waits
for notification completion, preserves the native return, records incomplete
capture, prevents another source read, and supports a canceled concurrent
finish waiter. Controlled gate guards release after five seconds on failure;
passing paths complete immediately and cancel the guards.

Public consumer proofs cover non-Codable values, keyed mixed modes, persistence,
merge, time, clock, scheduling, actor delivery, exclusive selection, claims,
consumption, recursive/open domain records, and managed incremental drafts.
Additional proofs cover resolved-baseline validation, headered same-value tracks,
duplicate/foreign declarations, copied and repeated lookup, validation-only
admission, fresh executions, zero activation after later validation failure,
throwing operations/sinks, snapshot freshness, reverse rollback, cleanup failure,
callback/cancellation destructor reentry, late freeze registration, and failed
construction releasing callback captures and closing escaped scheduling.

One old mismatch-construction assertion becomes derived-identity validation:
the public constructor no longer accepts a separately supplied attachment/type.
Compiler probes reject that former surface. A typed-layout failure now precedes
that system's optional validation hook; the facade test checks the exact failing
track and zero activation instead of expecting the old preparation callback.
These are consequences of Core deriving/preparing layout, not relaxed admission.

## Verification and commit structure

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

1. `f93a9d4`: typed definitions, managed state, scoped operations, diagnostic
   buffering, joins, snapshots, and initial public proofs.
2. `7afe041`: Random/Date migration and the two R1 regressions.
3. `c190532`: deferred effects, cancellation release, managed incremental time,
   sequential/persistent consumer migrations, and race/rollback proofs.
4. `3fb2483`: complete public-consumer migration, legacy-surface retirement,
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
