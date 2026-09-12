# Plan index

Plans record how approved work is ordered and reviewed. They are distinct from
design decisions: decisions define the intended product behavior, while plans
define a process for reaching an outcome.

Only a plan marked `Approved` or `In progress` is actionable. A completed plan
is retained for traceability and must not be interpreted as current work merely
because its original instructions use future tense.

## Statuses

| Status | Meaning |
| --- | --- |
| `Draft` | Under discussion and not approved for implementation. |
| `Approved` | Accepted and ready to begin. |
| `In progress` | At least one approved plan item is being implemented. |
| `Complete` | Its outcome has been delivered and the plan is historical. |
| `Superseded` | Replaced by another linked plan. |
| `Abandoned` | Deliberately stopped without completing its outcome. |

## Plans

| Number | Plan | Type | Status | Created | Completed | Outcome |
| --- | --- | --- | --- | --- | --- | --- |
| 001 | [Design decision process](001-design-decision-process.md) | Design process | Complete | 2026-09-04 | 2026-09-05 | [Decisions 1-12](../design-decisions/README.md) |
| 002 | [Follow-up design decisions](002-follow-up-design-decisions.md) | Design process | Complete | 2026-09-05 | 2026-09-06 | [Decisions 13-17](../design-decisions/README.md) |
| 003 | [Clean-slate implementation](003-clean-slate-implementation.md) | Implementation | Approved | 2026-09-06 | — | [Complete initial implementation](003-clean-slate-implementation.md#completion-criteria) (planned) |

Plan 003 was approved by the owner on 2026-09-07; implementation has not started.
It divides the initial product into atomic review units grouped by milestone,
with explicit prerequisites, verification, exclusions, and owner checkpoints
before implementation, PR creation, merge, or continuation to another unit.
Its [review questions and gates](003-clean-slate-implementation.md#unresolved-gates-and-evidence-dependent-choices)
record Q1–Q3 as owner-resolved: provisional task planning with reviewed
interception evidence before dependent production work, updated Apple deployment
minima, and separately retained post-finish diagnostics with an immutable final
report. Q4–Q5 remain evidence-dependent choices at their named implementation
checkpoints; plan approval does not resolve or bypass those gates.

## Plan metadata

Every plan begins with:

- status;
- creation date;
- approval date when approved;
- completion date when complete;
- predecessor, successor, or superseding plan where applicable;
- a link to its intended or delivered outcome.

Dates use ISO 8601 calendar form (`YYYY-MM-DD`). Plan numbers are allocated in
creation order and are never reused. Renaming a plan does not change its number.

An implementation plan also identifies atomic tasks, prerequisites, acceptance
criteria, verification, explicit exclusions, and a review checkpoint. Agents
summarize the selected unit and wait for owner confirmation before implementing
it. After verification, they mark the unit complete in its owning plan and
present the complete branch diff against its base, including any uncommitted
changes and the actual commit breakdown, then stop for owner review. Later
documented tasks never authorize continuation.

Review units should be split into smaller atomic commits when possible and
useful; the actual boundaries may be chosen during implementation. Once the
unit's scope is confirmed, feature-branch commits and history rewrites,
including published history, need no per-commit approval. Explicit
leave-uncommitted instructions and dependency approval stops still apply.

Owner approval to create a PR authorizes pushing its feature branch and later
updates for that unit, including rewritten history. Follow
[AGENTS.md](../../AGENTS.md#branch-and-commit-rules) for safe push and history
boundaries. Merge requires passing required CI for the revision being merged
and a separate explicit owner request; starting another unit requires its own
explicit instruction. Status changes belong in the PR that delivers them so
the base branch is accurate after merge. Write plan and evidence status in its
final merge-ready form without transient notes that hosted checks are pending.
Assume required PR checks pass when preparing those documents, then address any
failure before merge.
