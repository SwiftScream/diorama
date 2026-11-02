# 003-G07A: Request-started authorization tracking

- Status: Complete; owner review is complete and PR creation is authorized on
  2026-11-02.
- Authority: Owner approves the preparatory behavior change and G08 restack on
  2026-11-01 after reviewing the two native authorization mismatches.
- Branch: `feat/003-g07a-location-request-tracking`.
- Review base: `master` at `bb2b0cd`, including merged G07.
- Plan: [G07A](../plans/003-clean-slate-implementation.md#003-g07a--request-started-authorization-tracking).
- Contract: [DD16's tracking amendment](../design-decisions/16-location-system.md#request-started-authorization-tracking--owner-approved-2026-11-01).

## Behavior

Clients may request when-in-use or always authorization before assigning a
delegate. The first request starts the same access timeline as registration:
replay claims the initial segment, acknowledges it immediately when empty, and
then attempts the matching request barrier. A pending initial notification still
makes the request early; a wrong request leaves the reached barrier available
for a later matching request. Requests never skip pending notifications or
request markers. No new persisted fields or consumption units are introduced.

Scheduled access changes install complete current state without a delegate.
Later registration attaches callback delivery to the existing timeline without
redelivering missed changes or resetting deadlines. Reads alone remain
non-consuming. Finish cancels pending work and leaves escaped state frozen.
G08 separately applies these semantics to native capture, including keeping
pre-tracking record-mode state at its captured initial value.

## Verification

Focused access/facade tests cover both request kinds before registration,
request-relative deadlines, complete state before a delegate exists, later
registration without redelivery, wrong-first-request recovery, and finish
without ever registering a delegate. Existing tests retain early/wrong/duplicate
barrier checks, callback reentrancy, delegate replacement, and shutdown drainage.

Focused access/facade verification passes all 24 tests. `scripts/check` passes
pinned formatting, strict lint, all 592 host tests, both public compiler-probe
suites, warning-as-error Debug/Release compilation, and example builds and runs.

The selected local environment is Xcode 27.2 (`27B52`), Apple Swift 6.4.2, and
macOS 27.2 (`26B123`). This is not evidence for the older pinned Xcode 27.0
selection or iOS runtime behavior. The full platform and coverage matrix remains
a required PR gate. No iOS or Linux run is claimed for this review update.

## Review boundary

The preparatory behavior commit contains replay, facade documentation, tests,
the approved contract amendment, and owning plan/evidence updates. A separate
documentation commit records completed review and PR authorization. The owner
authorizes pushing G07A and creating its PR into `master` on 2026-11-02. Required
PR checks enforce the full platform and coverage matrix; merge requires a
separate explicit owner request.

G08 is restacked above this prerequisite. Native capture feedback remains a
separate adjacent, unsquashed fixup for owner review; this PR contains no native
bridge changes and does not authorize G08 PR creation, merge, or G09 work.
