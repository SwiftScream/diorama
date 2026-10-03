# Named checkpoint design notes

- Status: Exploratory; not an accepted design decision or approved implementation unit.
- Recorded: 2026-10-03, during 003-F02 review.
- Revisit: After 003-F05 review, using its insertion, removal, and override evidence.

## Problem

The accepted wall clock replays unlabelled `now` calls in attachment order. An
added or removed read can shift later values to different call sites. An extra
read may eventually exhaust the track, and an omitted read may leave unused
content, but neither fact identifies where the calls diverged. An insertion and
removal can also leave the final count unchanged. Position-based authored
overrides are exposed to the same drift, as [Decision 15](design-decisions/15-clock-system.md)
acknowledges.

Other sequential systems may have a similar diagnosis problem. Systems with
semantic matching, such as HTTP, need their own definition of progress; a raw
record count is not a universal answer.

## Working idea

A test could call a named checkpoint between meaningful actions without adding
Diorama concepts to the system under test. Core would own the checkpoint's
identity, order, and diagnostic context, and notify participating systems.
Each system would record and later verify the progress meaningful to its own
capability. For example, a clock checkpoint after two wall reads could report
that replay reached the same checkpoint after three reads.

This suggests a shared checkpoint event with system-specific storage and
verification, rather than dividing every system payload into a generic array
of payloads. The exact API, persistence location, and participation policy are
not decided. A name is valuable for diagnostics; whether unnamed checkpoints
are useful remains open.

## Intended limit

A checkpoint can localize a divergence to a section of a test. It cannot
identify which unlabelled read within that section changed. Shifted values may
already have been returned before the checkpoint, and compensating changes
within one section may escape a count comparison. Checkpoints should not be
described as automatic call-site matching or cursor repair.

Checking per-system progress at a named boundary also does not, by itself,
establish a single atomic event across concurrent tracks or enforce their
interleaving. Explicit cross-track ordering remains separately deferred by
[Decision 3](design-decisions/03-recorded-behaviors.md) and
[Plan 003](plans/003-clean-slate-implementation.md#explicitly-deferred-work).

## Questions for full design

- How does a checkpoint order against concurrent wall reads, in-flight HTTP
  interactions, and stream deliveries? Must callers establish quiescence first?
- Are names unique within an execution, or can a name recur with a stable
  occurrence number? Must every configured attachment participate?
- What stable progress does each capability record and compare? For matched
  interaction groups, a positional count alone may reject valid reordering.
- Where do checkpoint names and system progress live in the semantic model and
  versioned persistence? How do record, replay, passthrough, ignored systems,
  re-recording, and edited snapshots treat them?
- What mismatch diagnostic and nonthrowing continuation are appropriate when a
  checkpoint discovers a drift after values have already been returned?
- Is the first useful capability only per-system verification, or is a later
  explicit cross-track ordering feature needed?

## Revisit and placement

After 003-F05 review, update this note with evidence from inserting and
removing clock observations and from positional override merging. Assess the
actual diagnostics and whether the initial library is usable without named
checkpoints. Then choose a separately scoped, owner-approved design and review
unit if warranted. Possible placements are immediately after Phase F, at the
end of Plan 003, or in a successor plan. None is selected or authorized here.

The accepted [track model](design-decisions/01-common-abstraction.md),
[clock selection rule](design-decisions/04-replay-selection.md), and
[clock decision](design-decisions/15-clock-system.md) continue to govern the
current implementation.
