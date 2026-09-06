# Contributing to Diorama

Diorama is being built from an accepted design through small, reviewable
implementation slices. Correctness, deterministic behavior, and honest
capability boundaries take priority over breadth.

## Workflow

1. Start from an up-to-date `master` branch.
2. Create a descriptively named feature branch before editing.
3. Select one implementation-plan item or similarly atomic documentation task.
4. Implement its acceptance criteria without pulling in later plan items.
5. Run the required formatting, linting, build, test, and platform checks.
6. Present the uncommitted change for review and address feedback.
7. Commit and merge only after explicit approval.

Never commit directly to `master`. Keep unrelated changes out of the branch and
do not rewrite another contributor's work to simplify a review.

## Design changes

The accepted documents under `docs/design-decisions` define the architecture.
An implementation concern may reveal that a decision is infeasible, especially
around URLProtocol or cross-platform behavior. Record the evidence and reopen
the smallest affected decision instead of silently weakening the contract.

New features outside the accepted initial scope require design discussion before
implementation. This includes deferred task families, virtual-time policies,
semantic JSON normalization, new platform promises, and expanded consumer
extension mechanisms.

## Dependencies

Third-party production dependencies require explicit approval under
`docs/dependency-policy.md`. Isolated exploratory spikes are permitted, but they
must not alter production manifests or become an implicit architectural choice.

## Quality

The canonical checks and CI expectations are defined in
`docs/quality-gates-and-ci.md`. Code should compile with complete strict
concurrency checking and remain warning-free under the repository's pinned
SwiftFormat and SwiftLint configurations.

Every behavioral change needs focused tests. Cross-module contracts,
concurrency, persistence compatibility, and native adapters require broader
integration or conformance coverage appropriate to their risk.

## Review notes

A review request should state:

- the plan item or decision it implements;
- the observable behavior added or changed;
- the files and public surface affected;
- the commands and platforms verified;
- any known limitation, deferred case, or follow-up question.

Reviewable diffs should not contain formatting churn, unrelated refactors, or
generated output unless the active task requires them.
