# 003-E05: Record selection and consumption

- Recorded: 2026-10-07
- Status: Complete; the owner requests separate delivery above E04R on 2026-10-07.
- Decision: [System-owned records and shared execution services](../design-decisions/19-system-owned-records.md).
- Plan: [Revised E05](../plans/003-clean-slate-implementation.md#003-e05--system-selectors-and-atomic-record-claims).
- Base: `master` at `de6058e`, including merged E04R and F03 wall recording.
- Branch: `docs/interaction-primitives-design-review`; PR #62.
- Prerequisite: [E04R recording evidence](003-E04R-system-owned-records.md), merged separately in PR #65.

## Delivered boundary

`ReplaySelector<Input, Value>` selects arbitrary typed records without lifecycle
conformance. Selection callbacks and safe-difference projections run outside
lease isolation; Core validates identities and atomically claims the earliest
available equivalent record. No match, exhausted matches, unresolved ambiguity,
invalid identities, wrong mode, and closed access retain distinct diagnostics.

A claim reserves a record once and starts unconsumed. `markConsumed()` acknowledges
that all recorded behavior has been replayed, including reaching an open horizon.
It does not terminate the simulated operation. `consumeNext()` replaces
`claimNext()` and atomically claims and consumes synchronous values. Both paths
share availability; cancellation and abandonment never return a claim.

Reports retain ordered identities, monotonic progress, and `isConsumed` facts.
`allRecordsClaimed` and `allClaimedRecordsConsumed` independently evaluate selection
and replay. The `allowsUnclaimedReplayRecords` waiver only affects the former;
open recordings receive no consumption exemption. Acknowledgements remain
available during quiescence until lease closure freezes the report.

The recording APIs and generic-helper removal are E04R prerequisites, not part
of this PR's implementation diff. Full HTTP/location models, traversal engines,
and native conformance remain assigned to their domain units. No dependency,
persistence schema, deployment floor, or native adapter changes here.

## Behavioral evidence

Tests cover reordered inputs, equivalent FIFO, concurrent claims, sequential and
matched interoperation, attachment isolation, foreign/invalid identities,
callbacks outside locks, finish racing selection, monotonic progress, idempotent
consumption, abandoned claims, and immutable reports. Open-record tests require
explicit consumption acknowledgement without manufacturing domain termination.

Public-only consumer tests prove scalar matching and capture/freeze/selection
of a recursive HTTP-shaped record with challenge/retry and a failed partial body,
plus an open record. They establish public service access; they are not a
production HTTP schema or native URLSession conformance claim.

Controlled-clock tests derive a 50 ms continuation delay from a recorded answer
at 600 ms and response at 650 ms. Replay answers at 200 ms and 2 seconds deliver
at 250 ms and 2.05 seconds. This proves the shared services preserve the domain's
current-decision anchor without including application wait time.

## Verification and split integrity

- The original split preserves the source/test tree from the reviewed combined
  branch at `8b3f895` and published revision `fa60c15`. The subsequent rebase onto
  `master` at `6e1cf4c` preserves E05's implementation patch while incorporating
  the upstream generic random source and its shared-reference regression test.
- The rebased implementation passes canonical `scripts/check`: formatting,
  strict lint, all 281 host tests, warning-as-error debug/release builds, and
  example execution. The earlier immediate-recording rename passes 31 focused tests.
- The earlier claim/consumption implementation passes 280 tests on each of macOS,
  iOS Simulator, and pinned Linux. Its macOS PR patch coverage is 200/202 changed
  executable lines (99.01%). These are prior combined-review results; required
  CI and coverage apply independently to each published split PR revision.
- The rebased E04R-only prerequisite independently passes canonical checks and 267 host
  tests. Its evidence records that smaller review boundary.
- After PR #65 merges, rebasing directly onto `master` at `06fcbea` preserves
  the complete file tree before documentation updates; source and tests remain
  unchanged from the implementation verified above.
- A subsequent rebase onto `master` at `de6058e` incorporates F03 wall recording.
  Its callers migrate from `append` to `record` and from
  `allowsUnusedReplayRecords` to `allowsUnclaimedReplayRecords`, preserving
  wall-source behavior. Canonical `scripts/check` passes with all 295 host tests,
  formatting, strict lint, warning-as-error debug/release builds, and example
  execution. The E05 diff contains only these additional consumer API migrations;
  the merged F03 tests remain unchanged.

Historical combined review evidence remains in the pre-split Git history. This
record assigns replay verification to E05 without presenting it as E04R delivery.
The required PR platform checks and explicit owner approval govern E05 merge.

## Review sequence

1. `003-E05: feat(core): select records and track consumption`: selection,
   claim/consumption reporting, consumer migration, and proving tests.
2. `003-E05: docs(evidence): complete record selection work`: E05-only status,
   implementation guide, and evidence above the separately completed E04R unit.

E04R is integrated through PR #65. E05 now targets `master` directly; its
approval does not start E08 or authorize a merge without an explicit owner request.
