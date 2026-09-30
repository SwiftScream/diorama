# 003-E05: System selectors and atomic grouped claims

- Date: 2026-09-30
- Status: Implementation and local macOS, iOS Simulator, and Linux verification
  complete; owner review is the next checkpoint.
- Authority: The owner confirmed E05's documented scope and requested
  implementation after the plan's GPT-6 Sol, `high` recommendation was
  presented. The session's model settings were not changed by the agent.
- Review base: `003-e04-grouped-lifecycle`, stacked above merged F02.
- Prerequisites: [E04 evidence](003-E04-grouped-lifecycle-accumulation.md),
  [B04 evidence](003-B04-atomic-sequential-operations.md),
  [B08 evidence](003-B08-concurrent-finalization-and-evaluation.md),
  [DD04](../design-decisions/04-replay-selection.md), and
  [DD05](../design-decisions/05-consumption-and-verification.md).

## Public contract

A `GroupedReplayRecording` declares whether its strict conclusion is open at
the recording horizon. E04 interaction and subscription recordings conform;
custom systems may provide their own stable grouped type. A
`GroupedReplaySelector` compares a stable live input with all prepared records
in one keyed track. It returns equivalent identities, no match, or an explicit
ambiguous set. Exact-input and sequential helpers cover common policies.
Equivalent groups advance through available records in recorded order.

`SequentialTrackLease.claimGrouped(matching:using:)` validates selector output,
checks current availability, and claims one complete group under the lease
lock. Missing, exhausted, ambiguous, invalid selector, wrong-mode, and closed
use remain distinct safe diagnostics. Exhaustion and ambiguity retain matching
record identities; the selector may add only setup-authored rule and field
labels. Replay has no live fallback. The
[grouped replay selection guide](../grouped-replay-selection.md) describes the
public API and system responsibilities.

Each claim is used at selection, including an open group or one whose later
work stops. Its progress count and reached conclusion are separate facts. A
track reports exact unused identities even when claims leave holes. Scenario
evaluation gains an opt-in `allSelectedRecordingsCompleted` condition, scoped
to the whole scenario or selected attachments. An intentionally open group
satisfies that condition; an unfinished terminal group does not. The result
remains framework-independent and assigns no test outcome.

## Atomicity and lifetime argument

The selector and safe-difference callback run outside the lease lock over an
immutable baseline snapshot. The baseline cannot change during replay. The
core validates every returned identity against the selected track, then checks
availability and inserts the chosen index in one lock acquisition. Concurrent
callers therefore cannot claim the same group. The operation releases the
lock before recording or notifying a diagnostic sink. A selected group never
returns to availability, even when its claim is abandoned or later progress
stops.

The lease retains lightweight progress by record index. The private claim
holds its immutable stable record and forwards monotonic progress updates to
the lease; updates after closure cannot change frozen usage. Finalization
detaches baseline values, freezes ordered unused and selected identities, and
clears mutable claim state. The prior sequential API shares the claimed-index
ledger; sequential-only cursor order and exhaustion behavior remain unchanged.

## Proving tests

- Reordered distinct inputs select their corresponding groups. Repeated
  equivalent inputs claim different outcomes FIFO, including a group with an
  explicit open horizon.
- Missing, exhausted, ambiguous, and invalid selector results produce
  distinct safe evidence without claiming a record. Duplicate, foreign, and
  unknown identities are invalid selector results.
- Thirty-two concurrent equivalent calls claim thirty-two different groups;
  a selector reenters lease inspection without running under its lock.
- Sequential selection advances once, abandoned work remains used, and closed
  use enters the post-finish diagnostic log without changing the result.
- Pending, completed, and open claim states render deterministically. Unused
  identities remain ordered when a middle group alone was claimed. The unused
  waiver does not waive selected-completion evaluation.
- A consumer module imports only public APIs to prove custom non-Codable
  grouped values, separate keyed attachments, selectors, and attachment-scoped
  evaluation.

## Verification

| Gate | Result |
| --- | --- |
| Focused E05 suites | Seven core tests and one public consumer test pass. |
| `scripts/check` | Pinned format and strict lint report zero violations; all 257 macOS host tests, warning-as-error debug and release builds, and the example pass. |
| `scripts/coverage swiftpm macos` | All 257 tests and release/example checks pass; LCOV exported. |
| `scripts/coverage ios` | Release build and all 257 tests pass on iPhone 17 / iOS 27.0 Simulator at the iOS 18 deployment floor; LCOV exported. |
| Pinned Linux container reproduction | All 257 tests, warning-as-error release builds, example execution, and LCOV export pass on the accepted x86_64 image. |
| Local executable patch coverage | macOS and iOS each cover 202 of 208 changed executable source lines (97.12%), above the 90% patch target. |
| Diff and documentation | The complete branch diff against E04 passes `git diff --check`; changed local documentation links resolve. |

Apple verification uses Xcode 27.0 (`27A266a`) and Apple Swift 6.4. Linux
uses the digest-pinned Swift 6.4 Ubuntu image and the 2 CPU / 4 GB Apple
Container command from the [quality policy](../quality-gates-and-ci.md#local-entry-points).
The local Apple runs use macOS 27 and an iOS 27 Simulator with macOS 15 and
iOS 18 deployment floors; they do not establish runtime behavior on the
minimum OS releases.
The Linux example launcher emits its known `safeExec` signal 32/33 notices;
the example and all required gates succeed. Hosted CI and Codecov remain
merge gates; no hosted result is claimed here.

## Review boundary

The feature commit contains the core selector and claim boundary, exact and
sequential helpers, diagnostics, usage/evaluation/rendering, tests, and the
public guide. A separate evidence commit records this plan status and local
verification. No persistence schema, HTTP projection, scheduler delivery,
native adapter, package dependency, or deployment minimum changes in E05.
E06 and E07 own capability-specific event delivery and continuation timing.
