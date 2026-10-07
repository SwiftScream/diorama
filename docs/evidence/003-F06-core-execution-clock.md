# 003-F06: Core execution Clock and closed-handle behavior

- Recorded: 2026-10-08
- Status: Complete.
- Authority: On 2026-10-07, the owner approves moving the execution clock into
  Core, revising F06/F07, and commencing implementation after the documentation
  amendment, with the recommended GPT-6 Astra at `high` reasoning.
  The owner approves the execution-context review update, fixup consolidation,
  branch publication, and PR creation into `master` on 2026-10-08.
- Plan: [F06](../plans/003-clean-slate-implementation.md#003-f06--core-execution-clock-and-closed-handle-behavior).
- Review base: `master` at `de8cbc5`, including completed F05.
- Branch: `003-f06-core-execution-clock`.
- Decisions: [DD14](../design-decisions/14-real-time-replay-scheduler.md),
  [DD15](../design-decisions/15-clock-system.md), and its approved
  [execution-clock ownership amendment](../design-decisions/15-clock-system.md#execution-clock-ownership-amendment--owner-approved-2026-10-07).

## Delivered API and ownership

`DioramaCore.ScenarioClock` conforms to Swift `Clock`. Every successful
`ScenarioExecution` exposes `context.clock`, including a run with no systems. System
authors receive the same clock through `SystemPreparationContext.clock`.
The single `Diorama.execute` operation passes a `ScenarioExecutionContext` to
every scoped body before the configured typed dependencies. Its `clock` is the
same execution clock, preserving actor isolation, typed body errors, and ordinary
finalization/publication behavior. Inferred consumer values need only the
`Diorama` import. The [time-service guide](../execution-time-service.md) includes
the API, lifecycle contract, and compiled usage pattern.

Clock use creates no attachment, dependency key, wall track, persistence
registration, record, claim, or usage count. `DioramaClock` continues to own the
wall system. No wall API or schema changes.

`ScenarioClock.Instant` is a `Sendable`, `Hashable`, `Comparable` offset stored
as `Duration`. It contains no host instant or execution identity. A transferred
offset is interpreted against the receiving execution's origin. Signed and
subnanosecond arithmetic is retained. Its explicit symmetric supported range
is plus/minus `Int64.max` seconds and 999,999,999,999,999,999 attoseconds;
construction, arithmetic operands, and results outside it fail a precondition.
Mapping a valid logical deadline beyond the host timer's remaining range
instead produces a safe registration failure.

## Scheduling, cancellation, and finish

Sleeps use the existing execution deadline engine at the one-to-one real-time
rate. Past deadlines enter its next drain; every supplied tolerance uses the
stronger zero-tolerance policy. For equal deadlines, attachment deliveries
retain their existing order and precede execution sleeps; those sleeps follow
registration order. This determines handoff order, not application task
resumption order. `minimumResolution` retains the native source's scalar
resolution independently of its lifetime.

Each sleep coordinates continuation installation with task cancellation.
Cancellation before registration starts no timer. After registration,
cancellation and claim are atomic alternatives: pending cancellation throws
`CancellationError`, while a claimed sleep completes normally. The engine owns
queued canceled-sleep completions, including when a cancellation caller pauses
after removing an item. Its worker, failure path, or shutdown drains them
outside scheduler locks. Finish cannot leave an owned continuation handoff
behind. Application work resumed by a handoff remains application-owned.

The time service stamps the final horizon and closes admission under the same
time lock that serializes observations, before scheduler quiescence. Finish
cancels pending sleeps and joins claimed handoffs. Repeated or canceled finish
waiters share one result. A failed horizon emits safe evidence and invalidates
the complete recording candidate; the last valid instant remains the frozen
fallback. Existing backward-source tests now expect this additional finalization
fact instead of treating an unestablished horizon as healthy.

An escaped `now` reports `logicalTime(executionClosed)` and returns the horizon.
A new closed sleep throws `SchedulingFailure` carrying
`scheduling(logicalTime(executionClosed))`, distinct from canceled pending work,
including for a past deadline or already-canceled task. These diagnostics use
scenario context. Before startup or after an active clock read fails,
nonthrowing `now` reports the safe issue and returns the last valid instant or
zero. Native timer failures resume pending sleeps with the retained safe
`SchedulingFailure`; arbitrary underlying errors are neither retained nor
rendered.

Context and clock values keep the small time state and reporter, with a weak scheduler
reference. Suspended sleep frames do not retain the deadline engine. Finalization
releases the native source outside isolation. Source destruction may reenter
the escaped clock without deadlock. After report freezing, new misuse enters
the separately retained late log and cannot change the final result.

## Proving tests

The 22 added tests cover:

- Signed instant arithmetic, attosecond precision, identity-free equality and
  hashing, supported bounds, and four process-exit precondition checks.
- Attachment-free execution in record/replay/passthrough, generic Swift `Clock`
  use, native resolution, shared system-context clocks, and transferred
  deadlines between executions with different origins.
- Past deadlines, nil/zero/large tolerance, early timer wakes, and no recorded
  content or usage counts.
- Cancellation before registration, repeated pending cancellation, stale
  wakes, and a controlled claimed sleep whose timer join is suspended while
  caller cancellation and finish race.
- Finish draining queued cancellation while its worker joins a timer; 64
  concurrent sleeps racing cancellation, deadline claim, and shutdown.
- A horizon frozen at seven seconds while an already-claimed delivery drains
  and the controlled source advances to 100 seconds; concurrent canceled finish
  waiters, closed sleeps, and immutable reports with separate late diagnostics.
- Native timer failure, host deadline overflow, startup rollback, backward
  reads and failed horizons, weak scheduler ownership, and reentrant source
  destruction after source detachment. Retained contexts do not retain the
  deadline engine or injected native source.
- Public consumer access without a wall-system import or declaration, typed
  dependencies, MainActor isolation, body errors, and scoped cancellation.

The scheduler ordering test also covers execution sleeps alongside attachment
handoffs. Existing scheduler, capture, replay, wall, persistence, and consumer
suites run as regression coverage. Process-exit tests run on macOS and Linux;
iOS exercises valid arithmetic and all portable lifecycle tests.

## Verification

| Gate | Result |
| --- | --- |
| `scripts/check` | Pinned formatting and strict lint, all 367 host tests, warning-as-error debug/release builds, and release example build/execution pass. |
| `scripts/coverage swiftpm macos` | All 367 tests and release/example gates pass; macOS LCOV exported. |
| iOS coverage gate (canonical build/test/export) | Release build and all 366 applicable tests pass on iPhone 17 / iOS 27.0 Simulator with the iOS 18 deployment floor; iOS LCOV exported. |
| Pinned Linux reproduction | All 367 tests, warning-as-error debug/release builds, release example build/execution, and Linux LCOV export pass. |
| `scripts/verify-apple-toolchain` | All Xcode, Swift, SDK, and Simulator runtime pins pass. |
| Documentation and branch diff | Local links and anchors resolve; `git diff --check de8cbc5` passes for the complete unit. |

The iOS count excludes one desktop-only process-exit test containing four
precondition checks. All other new clock tests run on every required platform.

The context-review macOS export at `9c320d6` covers 243 of 247 changed executable source lines
against `de8cbc5` (98.38%). Uncovered lines are a queued cancellation drained
during a simultaneous timer failure, the existing capture-counter overflow
guard moved with the time-read helper, and the weak-scheduler fallback after
an execution disappears without explicit finish. Pending cancellation,
shutdown draining, timer failure, and normal explicit source/scheduler release
have direct tests. Hosted Codecov computes its own combined patch metric.

Apple verification uses Xcode 27.0 (`27A266a`), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), and macOS 27.0.1 (`26A434`).
The required Simulator profile is iPhone 17 / iOS 27.0 (`24A434`), with the
iOS 18 deployment floor. This profile does not establish minimum-runtime
execution on iOS 18.

Linux uses the canonical Apple Container profile: a read-only repository
mount, `x86_64`, two CPUs, 4 GB memory, and
`swift@sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9`.
Only package inputs are copied into `/work` for
`scripts/coverage swiftpm linux`. Its ephemeral LCOV is not retained locally
after the canonical `--rm` run.

Xcode emits its existing metadata-extraction notice for test bundles without
App Intents. The emulated Linux example emits the previously observed
`safeExec` signal 32/33 notices and exits successfully. Compiler and linter
warnings remain errors; no warning exception is added.

The standard protocol requirements are checked against the
[Swift Clock source](https://github.com/swiftlang/swift/blob/main/stdlib/public/Concurrency/Clock.swift)
and the installed toolchain. Range failures use Swift Testing's
[process-exit assertions](https://developer.apple.com/documentation/testing/exit-testing).

## Review boundary

### Execution-context review update — 2026-10-08

The owner approves replacing the two scoped body forms with one context-first
API. Core constructs immutable `ScenarioExecutionContext` values and exposes
them through `ScenarioExecution.context`. The context currently contains only
`clock`; system preparation retains its separate attachment-specific context.
All existing compiled consumer call sites and the random example accept the
additional first argument. The public-only clock tests return an escaped
context and verify frozen reads, rejected sleeps, immutable result diagnostics,
actor isolation, typed body errors, and cancellation cleanup. Core lifetime
tests retain contexts while proving scheduler and source release.

The review revision passes `scripts/check` and `scripts/coverage swiftpm macos`
with 367 tests, release builds, and the random example. The pinned Linux
coverage command passes the same 367 tests and release/example gates.
The iOS release build passes; all 366 applicable tests pass with coverage on
iPhone 17 / iOS 27.0. Concurrent Simulator startup and Linux emulation cause
resource contention, so the first iOS test invocation is interrupted. After
Linux completes, the canonical `xcodebuild test` command is rerun against the
same derived data with `.build/ios-context-tests.xcresult`; the canonical
`llvm-cov export` command exports `.build/coverage/ios.lcov`. Toolchain pins and
local documentation links also pass.

The owner approves squashing the F06 review fixups, pushing its feature branch,
and PR creation into `master` on 2026-10-08. The API, proving tests, call-site migration, and design
documentation are consolidated into the consumer API commit; the owning plan
and this evidence are consolidated into the evidence commit. F07's existing
stack is restacked and its consumer tests, example, and guide receive separate
compatibility fixups. Its macOS `scripts/check` passes all 374 tests and both
examples; that compatibility update does not claim new F07 platform coverage.

### Scheduler helper nesting review update — 2026-10-09

The owner selects a global `type_body_length` limit of 500 counted lines.
The root SwiftLint configuration sets both warning and error thresholds to
500; strict lint and the established test-directory exceptions remain in
effect. The policy and quality-gate documentation form a separate tooling
commit preceding the Core implementation.

`DeadlineEngine` again owns nested private `Item`, `State`, and `Work` types.
Its private scheduled-work payload and timer-range helper are nested there as
well. The externally shared handoff-order type remains at module scope.
The refactor changes only declaration scope and restores the short nested
type names. Comparing the remaining engine implementation against `9c320d6`
confirms identical code after substituting those names.

Focused existing scheduler/clock tests pass: 38 tests in seven suites.
`scripts/check` passes strict formatting/lint, all 367 host tests,
warning-as-error debug/release builds, and the release random example.
No additional tests are needed for the declaration-only refactor. The broader
coverage and iOS/Linux results above describe the preceding context-review
revision; those platform runs are not repeated for this update.

The owner approves the scheduler review update, fixup consolidation, and branch
publication on 2026-10-09. The scheduler update is consolidated into the Core
implementation commit; this evidence and the owning plan update are consolidated
into the evidence commit. The owner's instruction to stop monitoring hosted
checks remains in effect.

### Commit breakdown

1. `003-F06: docs(design): move execution clock ownership into Core`: approved
   DD15 amendment, decision index, consolidated overview, and revised F06/F07.
2. `chore(lint): raise the type body length limit to 500`: global root policy
   and its quality-gate documentation.
3. `003-F06: feat(core): expose the execution scheduler as a Swift Clock`: Core
   API, shared scheduler and horizon integration, ownership/race tests, and
   time/scheduling documentation.
   The approved review update restores nested private helper types.
4. `003-F06: feat(diorama): pass execution context to scoped bodies`:
   one context-first consumer API, public consumer proof, migrated call sites
   and examples, DD18's approved amendment, and escaped-context lifetime proof.
5. `003-F06: docs(evidence): record execution clock verification`: completed
   unit status, this evidence, and the documentation index.
   The approved scheduler nesting review update is included in this evidence.

No third-party dependency, deployment increase, unsafe concurrency annotation,
warning exception, or virtual-time control is introduced. F07 is a separate
stacked review unit owning broader wall-platform and mixed-system composition
evidence. Hosted required checks and Codecov use the authorized PR workflow; passing
checks and a separate explicit owner merge request gate integration.
