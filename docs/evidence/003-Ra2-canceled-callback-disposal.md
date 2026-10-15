# 003-Ra2: Canceled callback capture disposal

- Date: 2026-10-15
- Status: Complete.
- Plan: [003-Ra2](../plans/003-clean-slate-implementation.md#003-ra2--join-canceled-callback-capture-disposal)
- Authority: Owner request to fix Ra2 on a separate branch based on master and
  raise a PR.
- Base: `master` at `3b3f57b028f6992dc951965c79e0cf3497fb1ab9`.

## Behavior

`DeadlineEngine` counts detached cancellation disposal under the same lock that
removes pending work. It reuses `OperationTracker` with a separate admission
gate: common execution admission may already be closed when a public handle
cancels pending work. Scheduler stop closes disposal admission and removes the
remaining pending items atomically.

The task returned by scheduler stop joins both the worker and canceled capture
disposal. This join remains necessary when the worker exits before stop because
of a clock failure or closed admission. Core's existing finalization owner awaits
that task after requesting system stop, before cleanup and report freezing.

A private invocation scope releases direct cancellation's temporary references
before completing its disposal count. Under managed State protection, the capture
release and then its completion are queued as separate post-unlock actions.
Destruction can reenter committed State, scheduling, or reporting without holding
either lock. No scheduling policy, public signature, dependency, or accepted
decision changes.

Finish releases Core's callback ownership. An object also retained by consumer
code can outlive finish; its later release does not change the immutable final
report. A destructor that never returns can prevent quiescence, just as an
unfinished owned delivery can; no timeout or forced termination is introduced.

## Regression evidence

Before the fix, the controlled direct-cancel test reproduces a healthy final
candidate with no release diagnostic, followed by the canceled capture's
invalidating fact in the post-finish log. It does not demonstrate scheduled
delivery after finish.

`SchedulerDisposalTests` has three tests with seven cases:

- A dispatch-thread destructor waits on a gate while finish stops the scheduler.
  Concurrent finish callers, including already canceled callers, receive the same
  result only after disposal. Release-time invalidation appears in the final
  report and rejects the candidate. The same test covers a prior clock failure.
- Deferred cancellation keeps captures alive while a simulated State lock is
  held, then permits destructor reentry after commit. It also covers cancellation
  after common execution admission closes but before scheduler stop.
- Consumer-retained references remain outside the disposal join; their eventual
  destruction produces separate post-finish evidence.

The existing public `ManagedDefinitionTests` prove cancellation and destructor
reentry through actual State access. Scheduler cancellation, ownership,
quiescence, clock cancellation, and public resource lifecycle tests additionally
cover claim-versus-cancel races, inert terminal handles, callback-capture release,
stop-before-drain, and independent consumer-owned activity. Controlled signals
establish the race boundaries; the destructor's timeout is a deadlock guard, not
an elapsed-time assertion.

## Verification

On Apple Swift 6.4 (`swiftlang-6.4.0.34.1`) / Xcode 27.0 (`27A266a`):

- Focused Debug checks reproduce the original defect and pass with the fix.
- `swift test -c release -Xswiftc -warnings-as-errors --filter
  'Scheduler|ScenarioClockCancellationTests|ManagedDefinitionTests|ResourceSchedulingTests|ResourceLifecycleTests'`
  passes the focused scheduler and lifecycle suites with optimized lifetimes.
- `scripts/check` passes 456 host tests, formatting, strict lint, the coverage
  export fixture, public authoring and lifecycle compiler probes, Release builds,
  and both examples.
- V-doc checks cover links and anchors, plan status, the complete branch diff,
  and whitespace.

Required PR checks cover the current revision's macOS, iOS Simulator, Linux,
and Codecov matrix. Native Location and URLSession adapter evidence remains in
its owning future units.
