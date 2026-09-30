# 003-E06: Sequential stream delivery over grouped claims

- Date: 2026-10-01
- Status: Implementation and local macOS, iOS Simulator, and Linux verification
  complete; owner review is the next checkpoint.
- Authority: The owner confirmed E06's documented scope on 2026-09-30 after
  review of the GPT-6 Sol, `high` recommendation. The session's model settings
  were not changed by the agent.
- Review base: `003-e05-system-selectors`, stacked above merged F02.
- Prerequisites: [E03 evidence](003-E03-scheduler-quiescence.md),
  [E04 evidence](003-E04-grouped-lifecycle-accumulation.md),
  [E05 evidence](003-E05-system-selectors-and-claims.md),
  [DD03](../design-decisions/03-recorded-behaviors.md),
  [DD04](../design-decisions/04-replay-selection.md),
  [DD05](../design-decisions/05-consumption-and-verification.md), and
  [DD14](../design-decisions/14-real-time-replay-scheduler.md).

## Public contract

`SequentialTrackLease.replaySubscription` captures a fresh logical-time anchor,
uses the system's selector to claim one complete prepared
`SubscriptionRecording`, and returns a `StreamReplaySubscription` cancellation
handle. The system supplies an async delivery closure for values, nonterminal
failures, normal completion, and terminal failure. The
[stream replay guide](../sequential-stream-replay.md) describes the API and
timing contract.

Recorded offsets are mapped one-to-one from the subscription anchor. A normal
completion without an authored time follows the final event at its offset, or
the start for an empty group. An open horizon schedules no synthetic terminal
event. The helper registers one event at a time after the previous async
delivery returns, preserving each subscription's order even for equal offsets.
Different subscriptions may run concurrently; the helper does not impose
application-task ordering outside its delivery scope.

The whole group becomes used at selection. Reached events advance its separate
progress count; a terminal conclusion becomes complete only after its delivery
returns. Cancellation removes future work without returning the group to
availability or persisting caller cancellation. A claimed callback may finish
while cancellation or finalization proceeds.

## Lifetime and shutdown argument

The stream's lock serializes registering, pending, delivering, canceled, open,
and completed transitions. Registration never invokes a callback inline, but
the scheduler worker may race the return of registration; either order leaves
one accepted delivery. Cancellation before delivery starts suppresses it, and
cancellation during delivery prevents a successor while allowing the current
callback to finish. The scheduler joins claimed delivery before the track
freezes progress.

A claimed delivery that completes after execution admission closes attempts its
successor through an internal scheduling path that treats closure as ordinary
shutdown. Other scheduling errors retain the scheduler's safe diagnostic and
stop that subscription. The scheduler's pending callback owns the remaining
recording and adapter closure. The public handle holds only its phase and a
lightweight cancellation token, so an escaped handle does not retain the
payload after pending work is canceled or terminal delivery completes.

## Proving tests

- Repeated equivalent groups claim once each; a later subscription gets a
  fresh anchor. Values, nonterminal failure, recovery, and normal completion
  retain order at equal offsets.
- Empty normal and failed groups deliver their distinct conclusions; empty and
  emitted open groups never acquire a synthetic completion.
- Failed selection schedules nothing. Cancellation of pending work retains a
  used, incomplete claim and its reached event count.
- Cancellation during a suspended callback lets that callback finish without
  scheduling its successor. Finalization joins a suspended callback, suppresses
  a post-closure successor, and leaves no callback after quiescence.
- A retained public handle does not retain a pending callback capture after
  finalization. A consumer module uses only public APIs to replay an ordered
  stream and inspect completion.

## Verification

| Gate | Result |
| --- | --- |
| Focused E06 suites | Eight core tests and one public consumer test pass. |
| `scripts/check` | Pinned format and strict lint report zero violations; all 266 macOS tests, warning-as-error debug and release builds, and the example pass. |
| `scripts/coverage swiftpm macos` | All 266 tests and release/example checks pass; LCOV exported. |
| `scripts/coverage ios` | Release build and all 266 tests pass on iPhone 17 / iOS 27.0 Simulator at the iOS 18 deployment floor; LCOV exported. |
| Pinned Linux container reproduction | All 266 tests, warning-as-error release builds, example execution, and LCOV export pass on the accepted x86_64 image. |
| Local executable patch coverage | macOS and iOS each cover 138 of 147 changed executable source lines (93.88%), above the 90% patch target. |
| Diff and documentation | The complete branch diff against E05 passes `git diff --check`; changed local documentation links resolve. |

Apple verification uses Xcode 27.0 (`27A266a`) and Apple Swift 6.4. Linux
uses the digest-pinned Swift 6.4 Ubuntu image and the 2 CPU / 4 GB Apple
Container command from the [quality policy](../quality-gates-and-ci.md#local-entry-points).
The local Apple runs use macOS 27 and an iOS 27 Simulator with macOS 15 and
iOS 18 deployment floors; they do not establish runtime behavior on the
minimum OS releases. The Linux example launcher emits its known `safeExec`
signal 32/33 notices; the example and all required gates succeed. Hosted CI
and Codecov remain merge gates; no hosted result is claimed here.

## Review boundary

The feature change contains the core stream helper, an internal scheduling
closure path, controlled core and public consumer tests, and the public guide.
The evidence update records this plan status and local verification. No
location policy, per-emission matcher, caller-cancellation schema, dependency,
native adapter, or deployment minimum changes enter E06. E07 owns conditional
interaction delivery, and later first-party location work chooses its domain
and adapter policy.
