# 003-Fa09: Final-report-only diagnostics

- Date: 2026-10-12
- Status: Complete.
- Plan: [003-Fa09](../plans/003-clean-slate-implementation.md#003-fa09--final-report-only-diagnostics)
- Authority: The owner selects final-report-only diagnostics, defers in-flight
  inspection to test-integration design, and authorizes documentation,
  implementation, and a PR stacked on Fa09A. PR #82 merges before this PR is
  opened, so the Fa09 branch builds directly on its unchanged revision
  `8e5532b` on master. Fa02 remains separate and unimplemented.
- Contract: [DD05 amendment](../design-decisions/05-consumption-and-verification.md#final-report-only-diagnostics--owner-approved-2026-10-12),
  explicitly reconciled with DD10/DD20 and the earlier system decisions.

## Decision and alternatives

| Option considered | Workable contract | Tradeoff |
| --- | --- | --- |
| Keep unrestricted live sinks | Retain first, then invoke arbitrary consumer code with explicit reentry, overlap, failure, and lifetime rules. | Keeps immediate reaction but preserves the concurrency burden that motivated Fa09. |
| Restrict a live handler to supplied facts | A handler could log or form a test issue solely from its safe input, provided its framework context supports that call. Forbid access to Diorama state/dependencies. | Swift's closure type cannot enforce that restriction. Captures, overlap, throwing, test-context lifetime, and consumer violations remain concerns. |
| Explicit drain or finish callback | Deliver batches at an explicit boundary. | Needs ownership, ordering, reentry/failure, repeated-call, and duplicate-delivery semantics. A finish callback adds little beyond returning/storing a report. |
| Pull-only checks or snapshots, optionally cursored | Observe retained facts without invoking a callback; consumers decide whether to continue. | Can reuse ledger synchronization but introduces a new public observation boundary and policy. Deferred with test integration. |
| Final reports only — selected | Retain facts immediately; expose completed reports and separately retained post-finish facts. | Smallest delivery contract. No diagnostic-driven early intervention; existing native thrown errors and deterministic continuation still apply. |

The deferred [inspection considerations](../diagnostic-inspection-design-notes.md)
cover simple Boolean checks, health classification, non-consuming snapshots,
per-execution cursor watermarks, concurrent readers, final-report deduplication,
early abandonment, and test-context expiry. J01/J02 explicitly revisit them.
No context check method, checkpoint/cursor type, completion hook, or test
integration is implemented here.

## Delivered API and lifetime

`DiagnosticSink`, both `sink:` startup/initialization arguments, and
`DiagnosticIssue.sinkFailed` are removed, including rendering/evaluation cases.
`DiagnosticReporter.record` now only retains a safe value under its mutex.
It cannot invoke consumer code or turn a callback error into another diagnostic.

`DiagnosticReporter.report` becomes `DiagnosticReport?`: nil while collecting,
then the single immutable report produced by its execution owner's freeze.
It does not expose a running snapshot or let callers freeze a running execution.
Core `finish()` and startup failures retain their nonoptional completed reports.
Repository startup explicitly freezes its failure evidence instead of reading
an in-flight snapshot. Standalone reporters used by preparation helpers do not
independently finalize an execution.

The consumer layer keeps Fa09A's contract: `Diorama.report` includes finalization
and optional publication evidence before `execute` returns or rethrows the
original body error. No body-error wrapper or success-only reporting path is
introduced. The next admitted execution clears the stored report; sequential
reuse and rejection of overlap remain unchanged.

Health is derived from retained recording-impact facts. An internal check
allows merge admission to see invalidation before freeze without exposing an
in-flight public health API or sorting a temporary report. Final candidate
construction still uses the frozen report; recording, cleanup, publication,
and test outcomes retain their distinct policies.

One mutex orders diagnostic admission against freeze. Each racing fact belongs
to exactly one of the final report or post-finish log. Post-finish snapshots are
non-consuming and never change frozen health or usage. Report ordering remains
attachment/track/record order, using admission sequence for ties. Safe strings,
labels, and identity metadata remain the only retained diagnostic content.

## Concurrency audit

The production reduction is the sink callback, its captures, optional
configuration, thrown-error handling, recursive-failure avoidance, and public
active-ledger snapshots. There is no replacement delivery worker, stream, queue,
or subscriber lifetime. A source operation cannot reenter Diorama through a
diagnostic callback because that callback no longer exists.

Fa02's buffered notifications, managed effects, and notification joins were
planned/prototyped, not integrated in this baseline. This unit removes those
requirements from the active Fa02 plan and handoff; it does not claim to delete
unimplemented runtime machinery. The owner-requested stack order puts Fa09
before Fa02 rather than expanding this unit to implement managed state.

The audit retains execution and source locks, record reservations, atomic replay
claims/consumption, admission closure, scheduler cancellation and owned-delivery
joins, reverse rollback/cleanup, and release of callback captures outside locks.
`DeadlineEngine.fail/stop`, scheduling cancellation, lease freeze/merge callbacks,
and execution resource release still perform real non-diagnostic work. They are
not removed or weakened. Future managed `afterCommit` work and cancellation
callbacks must keep those same safe boundaries.

## Behavioral evidence

- Reporter tests prove nil before freeze, immediate internal health invalidation,
  deterministic context ordering, concurrent exactly-once retention, unchanged
  final health after late invalidation, non-consuming late snapshots, and
  release without retaining definition content.
- Finalization tests race 128 reporting tasks against freeze and retain exactly
  130 facts across the final and late logs, including one before and one after.
  Existing concurrent/canceled finish, rollback, cleanup failure, and escaped
  ownership tests remain.
- Preparation tests preserve safe typed errors and secret exclusion at every
  failing stage. Merge tests still refuse an unhealthy candidate before freeze.
- The Date conversion regression returns an unrepresentable native date,
  performs another successful read, and still refuses the unhealthy candidate;
  no report is exposed between reads.
- A public-only Random regression blocks a reserved source read, begins finish
  until leases are closed, then releases the source. The live value returns,
  incomplete/closed facts are retained, cleanup releases the source, and finish
  completes without diagnostic callback reentry. Replay exhaustion still returns
  zero without contacting the live source.
- Scheduler tests now wait for discarded-work capture release rather than a
  diagnostic callback. They still prove failed-clock cancellation, rejection of
  new work, and drainage of already claimed delivery. Existing callback and
  destruction reentry tests remain.
- The full consumer suite covers startup evidence, original body errors,
  cancellation, cleanup/publication failure, retained reports, sequential reuse,
  and lifetime. External examples still compile with public imports only.

## Local verification

Apple verification uses Xcode 27.0 (`27A266a`), Swift 6.4, and the repository's
strict concurrency and warnings-as-errors settings. The iOS run uses iPhone 17
with iOS 27.0 and deployment target iOS 18. The existing host-only clock test
accounts for the one-test difference on iOS.

| Gate | Result |
| --- | --- |
| Focused diagnostic, preparation, lifecycle, merge, scheduler, Random, and Date tests | 105 tests passed across 18 suites with compiler warnings as errors. |
| `scripts/check` | Passed: SwiftFormat, strict SwiftLint, coverage-export fixtures, 401 host tests, release library and external examples, and both example executables. |
| `scripts/coverage ios` | Passed: release build, 400 tests, fresh isolated LCOV export. All 27 changed executable source lines are covered in the iOS artifact. |
| Pinned Linux `scripts/coverage swiftpm linux` | Passed: 401 tests, release library and external examples, both example executables, and fresh isolated LCOV export. |
| Documentation | All local links/anchors in changed Markdown and `git diff --check` pass across the complete branch diff. |

The focused command is:

```bash
swift test --filter 'DiagnosticReporterTests|ValuePreparationTests|ScenarioExecutionTests|ConcurrentFinalizationTests|ReplayContinuation|SequentialTrackOperationTests|SchedulingLifetimeTests|SchedulerOwnershipTests|ScenarioClockLifetimeTests|DioramaRandom|ScenarioReportRenderingTests|WallSourceTests|RecordingMergeTests' -Xswiftc -warnings-as-errors
```

Linux uses Apple Container with the exact CI image, x86_64 architecture, two
CPUs, and 4 GiB memory. Only package inputs are copied from a read-only checkout:

```bash
container run --rm --name diorama-fa09-linux --arch x86_64 --cpus 2 --memory 4G \
  --mount type=bind,source="$PWD",target=/source,readonly \
  --workdir /work \
  swift@sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9 \
  bash -lc 'set -e; cp -R /source/Package.swift /source/Sources /source/Tests /source/scripts /source/Examples /work/; scripts/coverage swiftpm linux'
```

Xcode emits metadata-extraction notices for targets without AppIntents; Linux
emulation emits the existing `safeExec` signal 32/33 launcher warnings while
running examples. These are not Swift compiler diagnostics, and no compiler,
linter, or test gate is weakened. No actual iOS 18 runtime execution is claimed.

## Review boundary

The three commits contain the decision/plan/inspection notes, the API change
with its proving tests, and completed verification evidence/documentation.
The implementation revision is `13ca5d3`; subsequent changes are documentation.
The code change reduces the production surface without adding dependencies,
unsafe concurrency annotations, deployment requirements, persistence schemas,
automatic test policy, or native adapter scope.

This is intentionally a source-breaking removal of sink configuration and the
sink-failure enum case, plus optionalization of the reporter's completed report.
Callers migrate observations to `finish()`, startup-error evidence, or the
retained consumer report. In-flight inspection and test integrations remain
separate decisions; Fa02 does not start as part of this work. Merge requires
passing required checks and a separate owner instruction.
