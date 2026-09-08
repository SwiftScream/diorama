# AGENTS.md

This file governs agents working anywhere in the Diorama repository.

## Purpose

Diorama is a clean-slate Swift record/replay library for deterministic testing
of nondeterministic systems. It is not a continuation of the exploratory
`swift-network-snapshot` implementation and has no compatibility obligation to
that POC's package structure, APIs, persistence format, or tests.

The repository is initially documentation-only. Do not create production code
until an approved implementation-plan slice asks for it.

## Sources of truth

Read the documents relevant to a task before designing or editing code:

1. `docs/design-decisions/README.md` and the accepted decision documents;
2. `docs/design-overview.md` for their combined meaning;
3. `docs/plans/README.md` and the active approved implementation plan;
4. `docs/dependency-policy.md`;
5. `docs/quality-gates-and-ci.md`.

An implementation plan sequences work but does not override an accepted design
decision. If a task conflicts with a decision or requires an unresolved product
choice, stop that slice and surface the conflict. Do not silently choose a new
architecture inside implementation work.

## Branch and commit rules

- Always work on a feature branch. Never edit or commit directly on `master` or
  `main`.
- At the start of every task, inspect the current branch and worktree. If the
  current branch is `master` or `main`, create a descriptively named feature
  branch before editing.
- Keep one branch focused on one approved review unit unless the owner asks to
  combine work.
- Keep commits tightly atomic: each commit should contain one coherent
  reviewable change and the tests or evidence that prove it. Split
  repository-process, documentation-policy, tooling, and feature changes into
  separate commits when they do not directly serve the same review unit.
- When a behavior change needs preparatory refactoring, prefer an initial
  commit that preserves behavior, followed by a commit that implements the
  behavior change on top of it.
- Use the commit-message convention documented in `CONTRIBUTING.md`. For a
  plan unit, use `003-A01: docs(evidence): record local toolchain feasibility`;
  for work outside a plan, omit the prefix. Use an imperative subject, an
  approved type (`feat`, `fix`, `ref`, `docs`, `test`, `ci`, `style`, or
  `chore`), and a path-oriented scope when useful. Keep the body in present
  tense. Aim for a subject of 72 characters or fewer, but preserve clarity
  when a slightly longer subject is needed.
- After the owner confirms the review unit's scope, create atomic commits and
  amend, rebase, or otherwise rewrite its feature-branch history as useful,
  including published history. Separate approval for each commit or rewrite is
  not required. Explicit instructions to leave work uncommitted and dependency
  approval stops still apply.
- Feature-branch permissions never authorize rewriting `master` or `main`.
- Owner approval to create a PR authorizes pushing that feature branch and
  subsequent updates for the same review unit, including rewritten history.
  Before that approval, do not push or create a PR unless separately authorized.
  Use `--force-with-lease` when updating rewritten published history; inspect the
  remote state and preserve concurrent work rather than overwriting it blindly.
- Merge only after required CI passes for the revision being merged and the
  owner separately and explicitly requests the merge. PR approval, passing CI,
  and merge approval do not authorize starting the next review unit.
- Preserve changes you did not make. Work with relevant concurrent edits and
  leave unrelated edits untouched.

## Atomic implementation workflow

Implementation proceeds one small plan item at a time:

1. Read the plan item's prerequisites, referenced decisions, acceptance
   criteria, and exclusions.
2. Confirm the branch and inspect the existing implementation and tests.
3. Summarize the intended work and pause until the owner explicitly confirms
   the scope before implementation.
4. Implement only that item and the tests or documentation needed to prove it.
   Split it into smaller atomic commits when possible and useful, keeping
   behavior and its proving tests together.
5. Run the narrowest relevant checks, followed by the plan's required review
   gate.
6. After verification passes, mark the unit complete in its owning plan and
   evidence, then present the complete feature-branch diff against its base
   branch, including any uncommitted changes, for owner review. Report behavior,
   files changed, the actual commit breakdown, verification results, and any
   residual risk.
7. Stop for owner review; address feedback within the unit and rerun checks.
8. Once the owner approves PR creation, push the feature branch and create the
   PR. Include the completed unit/plan status and relevant documentation updates
   so merging produces the correct state on the base branch. Obtain the required
   CI evidence through the PR.
9. Merge only with passing required CI and a separate explicit owner request.
   Do not begin the next plan item until explicitly instructed.

A slice should establish one coherent capability or invariant. Avoid combining
foundational APIs, several systems, broad cleanup, and repository tooling in one
review unit merely because they are related in the overall plan.

Spikes are evidence-producing tasks. Keep them isolated from production code,
record their result, and do not turn an exploratory package into a production
dependency without approval.

## Architecture constraints

- A scenario can contain heterogeneous systems and several separately keyed
  instances of the same system.
- Stable semantic values are independent of native runtime object graphs.
- Record, replay, and passthrough are attachment behaviors; replay never falls
  through to a live dependency.
- Runtime models make lifecycle conclusions mutually exclusive. Tolerant
  persisted forms must validate into one strict interpretation before use.
- Timing is capability-specific. The initial scheduler maps logical delays
  one-to-one to monotonic real time.
- Diagnostics report infrastructure and verification facts. Diorama itself does
  not decide whether a test passes; integrations may opt into that policy.
- Persistence is optional at the core boundary. Persisted first-party systems
  use deliberate, versioned `Codable` schemas and deterministic JSON.
- `DioramaHTTP` uses Swift HTTP Types as in-memory currency while Diorama owns
  lifecycle, body, matching, transformation, and persistence semantics.
- Apple Foundation and FoundationNetworking are bridges for one URLSession
  system, with advertised behavior constrained by tested capabilities.
- Platform-specific live adapters must not leak native-only types into portable
  stable models.

Use the accepted decision documents for detail. This summary is not permission
to simplify behavior specified there.

## Swift and concurrency

- Bootstrap with the latest stable Swift tools and Xcode versions selected by
  the implementation plan and CI policy, subject to the owner-approved
  2026-09-07 beta bootstrap exception in `docs/quality-gates-and-ci.md`.
- Enable complete strict concurrency checking from the beginning.
- Prefer approachable concurrency features where they make isolation explicit
  and remain compatible with the supported platforms.
- Treat `Sendable`, actor isolation, cancellation, and quiescent finalization as
  API design concerns, not warnings to suppress later.
- Target iOS 18 and macOS 15 or later, plus the accepted Linux CI environment.
  Use the equivalent Apple deployment floors in `docs/quality-gates-and-ci.md`
  for any separately approved platforms. Keep Apple-only integrations behind
  explicit availability and package boundaries.

Do not add `@unchecked Sendable`, unsafe isolation annotations, or broad
availability increases merely to make a check pass. Each requires a documented,
reviewable justification.

## Dependencies

No third-party package may enter production manifests or accepted implementation
without the approval required by `docs/dependency-policy.md`.

Exploration may use a package in an isolated spike. Before production adoption,
report its exact repository, product, version rule, purpose, alternatives,
platform impact, and license for approval. An approved package does not imply
approval for unrelated products or future major upgrades.

Do not replace a platform or standard-library facility with a dependency solely
for convenience. Do not hand-roll a complex domain implementation when an
approved, established dependency is the intended design choice.

## Quality gates

Follow `docs/quality-gates-and-ci.md` from the first implementation slice.
Repository bootstrap must establish SwiftFormat and SwiftLint through Mint,
strict-concurrency compilation, tests, and GitHub Actions before feature work
depends on them.

- Formatting and linting configuration are version-controlled.
- Local and CI checks use the same canonical entry point.
- Compiler and linter warnings fail CI unless a narrowly documented exception
  is approved.
- Tests cover macOS, iOS, and Linux according to package availability.
- Coverage is collected and uploaded to Codecov without weakening test jobs.
- Third-party GitHub Actions are pinned to full commit SHAs.
- Dependabot maintains both Swift Package Manager and GitHub Actions
  dependencies, including Mint-managed tool declarations where supported.

Run all checks required by the active plan item. If an environment prevents a
check, report that fact precisely rather than claiming verification.

## Engineering rules

- Prefer small explicit types and existing accepted extension boundaries over
  speculative abstraction.
- Make invalid states unrepresentable in runtime models and validate edited
  persistence at one clear boundary.
- Keep native values inside adapters and prepare stable values before matching,
  diagnostics, resources, or persistence.
- Preserve deterministic ordering and output. Never rely on dictionary order,
  executor scheduling, locale, current time, or process identity implicitly.
- Add tests in proportion to the behavioral and concurrency risk of the slice.
- Do not add compatibility code for POC files or APIs unless a new accepted
  decision explicitly requires it.
- Avoid unrelated refactors, generated churn, placeholder public APIs, and
  future-feature scaffolding outside the current slice.

## Documentation

Update documentation when a slice changes a public contract, persistence
schema, supported capability, limitation, or implementation-plan status.

Use US English spelling in documentation, comments, diagnostics, identifiers,
and other code tokens. Preserve external names, quoted source text, protocol
and package names, and domain terms whose spelling is fixed by an external
standard.

Keep implementation progress in the owning implementation plan. Do not add
unit-status updates to the repository `README.md`, `docs/README.md`,
`docs/design-overview.md`, or `docs/plans/README.md`; those documents are stable
orientation and architecture indexes. When a slice produces an evidence
document, name it with its plan and unit prefix, such as
`docs/evidence/003-A01-toolchain-and-availability.md`, and update links from
the owning plan and documentation indexes as needed.

Accepted design decisions are historical architectural records. Do not rewrite
their decisions casually. A contradiction or material revision requires owner
discussion and explicit approval, recorded as a new decision or clear
amendment.

Keep `docs/README.md`, `docs/design-overview.md`, and plan status accurate as
artifacts are added. Only plans marked `Approved` or `In progress` are
actionable; completed plans are traceability records. Do not restore standalone
POC architecture documentation to this repository.
