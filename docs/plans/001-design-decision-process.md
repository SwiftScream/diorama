# Plan 001: Design decision process

- Status: Complete
- Created: 2026-09-04
- Completed: 2026-09-05
- Outcome: [Accepted Decisions 1 through 12](../design-decisions/README.md)
- Extended by: [Plan 002: Follow-up design decisions](002-follow-up-design-decisions.md)

This is a completed process record. It is not an active implementation plan.

## Purpose

This plan defines how the twelve open design decisions for Diorama will be
resolved. The goal is to make one small, reviewable decision at a time, retain
the reasoning behind it, and use the accepted decisions to produce a clean-slate
implementation plan suitable for unattended Codex work.

The twelve source decisions are summarized below. Their final status and
accepted documents are tracked in the
[design decision index](../design-decisions/README.md).

## Working cycle

Only one design decision is active at a time.

1. Codex prepares a proposed decision note.
2. The note tests the proposal against HTTP, location updates, and clocks where
   each example is relevant.
3. The note presents credible alternatives, tradeoffs, a recommendation, and
   focused review questions that still require the owner's judgment.
4. The owner reviews the proposal and supplies corrections, constraints, or
   approval.
5. Codex updates the note to reflect the discussion.
6. The note becomes `Accepted` only after explicit owner approval.
7. Codex updates the decision index and begins the next decision.

If evidence is missing, a small technical spike may be proposed. A spike must
have a narrow question and exit criterion; its result informs the decision but
does not silently become production architecture.

## Decision note format

Each note records:

- status and last-updated date;
- the exact question and dependencies on earlier decisions;
- relevant forces and representative use cases;
- viable options and their tradeoffs;
- the recommended answer;
- consequences and explicit non-decisions;
- questions requiring owner input;
- the final accepted answer once approved.

Statuses have these meanings:

| Status | Meaning |
| --- | --- |
| `Not started` | No proposal has been written. |
| `Proposed` | A recommendation exists and is under discussion. |
| `Accepted` | The owner has explicitly approved the recorded answer. |
| `Superseded` | A later decision replaces this one and links back to it. |

Accepted notes are not changed substantively without reopening the decision.
Clarifications that do not alter behavior may be added with a dated note.

## Decision order

The decisions are ordered by dependency rather than implementation area.

### Foundation

1. Identify the smallest useful common abstraction.
2. Divide shared semantics from integration-specific semantics.
3. Represent values, errors, callbacks, cancellation, ordering, and time.

### Replay

4. Choose replay selection strategies.
5. Define consumption, unused recordings, and end-of-test verification.

### Representation and persistence

6. Place the runtime-to-snapshot conversion boundary.
7. Decide whether persistence is fundamental or layered.
8. Set schema compatibility and migration expectations.

### Safety and lifecycle

9. Define normalization and redaction.
10. Assign ownership of loading, recording, flushing, verification, and cleanup.

### HTTP specialization

11. Decide when HTTP integrations share a transport-neutral model.
12. Define the supported `URLSession` surface and explicit exclusions.

## Consistency reviews

After decisions 3, 5, 8, 10, and 12, Codex will check all accepted notes for
contradictions, undefined terms, and assumptions that no longer hold. Any
conflict reopens the smallest affected decision rather than being resolved
implicitly in a later note.

The examples serve different purposes during these reviews:

- HTTP tests correlated calls, matching, transport-native values, and errors.
- Location updates test subscriptions, unsolicited values, ordering, timing,
  and failures.
- Clocks test synchronous observations, suspended work, deterministic time
  advancement, and coordination between dependencies.

## Final synthesis

Once all twelve decisions are accepted, Codex will produce a separate
clean-slate implementation plan. It will not treat the POC structure as a
required starting point.

The later [follow-up design decision plan](002-follow-up-design-decisions.md)
records the delivery policies and Decisions 13 through 17 that were required
before this synthesis gate was ultimately satisfied.

Each implementation task will specify:

- one bounded outcome;
- files or module boundaries in scope;
- public behavior introduced or changed;
- tests or other evidence required;
- dependencies on earlier tasks;
- explicit exclusions;
- a review checkpoint and completion criteria.

Tasks will be ordered so an agent can complete one unattended, stop for review,
incorporate feedback, and proceed without bundling unrelated architectural
changes.
