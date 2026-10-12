# 003-Fa09A: Sequential execution and retained final reports

- Date: 2026-10-12
- Status: Complete.
- Plan: [003-Fa09A](../plans/003-clean-slate-implementation.md#003-fa09a--sequential-consumer-execution-and-retained-reports)
- Authority: The owner approves the final-class conversion, sequential reuse,
  retained completed report, implementation, and PR into master. The accepted
  [DD18 amendment](../design-decisions/18-diorama-setup-and-scenario-data.md#sequential-reuse-and-retained-final-reports--owner-approved-2026-10-12)
  records that contract.

## Delivered boundary

`Diorama` is a final Sendable class. References share one admission gate and
completed report. A short `Synchronization.Mutex` transition admits execution
before startup; overlapping and nested calls throw
`DioramaExecutionError.executionAlreadyInProgress` without loading, activating,
or invoking the rejected body. There is no queue or callback added to the
consumer API. Separate instances can run concurrently.

The gate covers startup, body execution, rollback, Core finalization, and
optional publication. It is never held as a lock around those operations.
The internal scoped runner constructs the safe `DioramaReport` after
finalization and publication, before extracting the successful body value or
rethrowing the original body error. The outer execution stores that report and
releases admission in one synchronized transition. No execution, body result,
body error, or semantic definition is stored on the consumer object.

`report` is nil initially, during an admitted attempt, and after startup
failure. A new admitted attempt clears its predecessor's report. Startup
failure completes existing rollback, retains its structured error evidence,
and releases admission for reuse. An overlapping rejection leaves the admitted
attempt untouched. Both ordinary body failure and thrown cancellation preserve
completed diagnostic and publication evidence before the error escapes.
Cancellation with a successful body return also retains the final report.

Sequential replay still starts with fresh consumption state. Previously copied
reports remain immutable across later attempts and post-finish dependency
misuse. Callers coordinate await, report inspection, and the next attempt;
another task can begin a new admitted attempt before a previous caller inspects
the property. This gate is not a reservation of report ownership after return.

## Independence from Fa09

The change builds directly on the integrated consumer facade and does not
require the Fa02 authoring stack or Fa08 native lifecycle extension. Core
diagnostic sinks, retention, finalization joins, continuation policies, and
post-finish logs are unchanged. Publication remains governed by recording
health, independently of the body outcome. No new dependency, schema, platform
minimum, unsafe concurrency annotation, or test-framework integration is added.

Fa09 owns removal of live diagnostic delivery. In-flight inspection, simple
health queries, checkpoints, and cursors remain deferred to later
test-integration design. This unit only makes completed evidence accessible
when the scoped body throws.

## Behavioral evidence

- Public consumer tests prove reference identity, shared report access,
  sequential replacement, immutable saved reports, and unchanged final reports
  after late dependency misuse.
- Controlled gates prove overlap rejection during preparation, the body,
  cleanup, startup rollback, and repository publication. Rejected publication
  attempts do not even perform another repository read. Nested calls reject
  immediately, while separately constructed instances run together.
- A failed second activation clears a previous report, retains rollback
  evidence in `ScenarioStartupFailure`, and permits a third successful attempt.
- Body failure and cleanup failure coexist in their original error and retained
  report. Publication failure is likewise retained without replacing the body
  error. Existing publication cases prove healthy and unhealthy recording
  behavior for success, failure, cancellation, and canceled successful returns.
- Cancellation while the body sleeps initiates finalization but keeps admission
  closed until gated cleanup completes. The original `CancellationError`
  escapes only after the report is stored, and the instance remains reusable.
- Actor-isolated bodies preserve their actor and typed error behavior. Lifetime
  probes show that stored reports retain neither successful body values nor
  dependencies carried by body errors. Arbitrary error descriptions are never
  inspected or rendered.

## Verification

The focused command `swift test --filter 'DioramaTests|DioramaPublication'
-Xswiftc -warnings-as-errors` passes 38 tests across the consumer and publication
suites, including the new admission and retained-report proofs.

Apple Swift 6.4 / Xcode 27.0 (`27A266a`) passes canonical `scripts/check`:
402 tests, pinned SwiftFormat, strict SwiftLint, warnings-as-errors compilation,
release builds, coverage-script fixtures, and both external example executables.

`scripts/coverage ios` passes release compilation with the iOS 18 deployment
target, 401 tests on iPhone 17 / iOS 27.0, and a fresh repository-relative LCOV
export. All 19 changed executable lines in the consumer implementation are
covered. This simulator run does not establish runtime evidence on iOS 18.

`scripts/coverage swiftpm linux` passes 402 tests, release compilation, both
examples, and fresh repository-relative LCOV export in Apple Container using
the approved Swift 6.4 Ubuntu image
`swift@sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9`,
x86_64, two CPUs, and 4 GB. Inputs are copied from a read-only source mount
into the container's writable working directory, following the
[local Linux procedure](../quality-gates-and-ci.md). Existing emulation
launcher notices for signals 32 and 33 do not change the compiler's
warnings-as-errors policy.

Local Markdown links and anchors resolve. `git diff --check origin/master`
passes across the complete change, and the complete branch diff is reviewed.
The platform test counts differ by the existing host-only Core test.

## Commit structure

1. Record the owner-approved DD18 amendment, architecture reconciliation, and
   preparatory plan unit.
2. Implement final-class ownership, atomic admission, and retained reports with
   their lifecycle/publication proofs and public usage documentation.
3. Record verification evidence, index it, and complete the owning plan unit.
