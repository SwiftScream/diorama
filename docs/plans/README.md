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

Plan number 003 is reserved for the clean-slate implementation plan.

## Plan metadata

Every plan begins with:

- status;
- creation date;
- completion date when complete;
- predecessor, successor, or superseding plan where applicable;
- a link to its intended or delivered outcome.

Dates use ISO 8601 calendar form (`YYYY-MM-DD`). Plan numbers are allocated in
creation order and are never reused. Renaming a plan does not change its number.

An implementation plan also identifies atomic tasks, prerequisites, acceptance
criteria, verification, explicit exclusions, and a review checkpoint. Agents
stop after each task for owner review and do not commit or continue merely
because later tasks are documented.
