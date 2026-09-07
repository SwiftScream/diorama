# Plan 003: Clean-slate implementation

- Status: In progress
- Created: 2026-09-06
- Approved by owner: 2026-09-07
- Preceded by: [Plan 001](001-design-decision-process.md) and [Plan 002](002-follow-up-design-decisions.md), both complete
- Intended outcome: [Complete initial implementation](#completion-criteria) of the [accepted design](../design-overview.md)

The owner explicitly approved this plan on 2026-09-07, alongside the consolidated design.
003-A01's scope was confirmed on 2026-09-07, with an explicit owner-approved
[beta toolchain exception](../quality-gates-and-ci.md#toolchain-policy).
003-A01 through 003-A03 are complete; later units have not started.
Plan approval establishes the implementation sequence and review boundaries; each selected unit still requires owner scope confirmation under protocol R before work begins.
The gates below require their own recorded resolution where they affect a unit; plan approval alone does not approve dependencies or amend an accepted decision.

## Outcome and boundaries

Deliver a usable swift library with heterogeneous, independently keyed systems; record, replay, and passthrough attachments; a public consumer extension boundary; optional deterministic file persistence; structured reports; random, clock, and location systems; shared HTTP semantics; and one URLSession system backed by tested Apple Foundation and FoundationNetworking bridges.
Include scoped execution and opt-in testing integrations, documentation, and the required quality and platform gates from the first implementation milestone.

The random system is the first complete vertical implementation, including persistence and finalization, before scheduler and native-adapter complexity.
Location and clocks are optional attachments, not prerequisites for using HTTP or random.

## Authority and reconciliation

Read [AGENTS.md](../../AGENTS.md), every decision referenced by the active unit, the [overview](../design-overview.md), the [dependency policy](../dependency-policy.md), and the [quality policy](../quality-gates-and-ci.md) before implementation.
All seventeen accepted decisions, both completed plans, and every other document under `docs` were considered when drafting this plan.
Decision references use DD01–DD17.
Review-unit IDs use phase letters A through J and local numbers, including 003-D01–003-D05 for interception evidence.
Older proposal examples and explicit deferrals must be read with their later accepted clarifications.

| Source                                                                                       | Required interpretation and principal units                                                                                                                                                                                                                                          |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [DD01: Common abstraction](../design-decisions/01-common-abstraction.md)                     | Independently ordered typed tracks in a heterogeneous scenario; repeated system instances have separate attachment keys. 003-B01–003-B05, 003-E04–003-E08, 003-J03.                                                                                                                                      |
| [DD02: Ownership layers](../design-decisions/02-shared-vs-system-semantics.md)               | Whole-attachment mode overrides; public system services; domain and adapter boundaries. 003-B01–003-B07, 003-E08, 003-H02–003-H04, 003-I01.                                                                                                                                                                  |
| [DD03: Recorded behaviors](../design-decisions/03-recorded-behaviors.md)                     | Mutually exclusive grouped conclusions, explicit open horizons, capability-specific timing, observed/override normalization. 003-E04–003-E07, 003-F01–003-F05, 003-G03–003-G06, 003-H05–003-H14.                                                                                                                     |
| [DD04: Selection](../design-decisions/04-replay-selection.md)                                | Stable inputs, deterministic system selectors, FIFO among equivalent candidates, explicit ambiguity and no live replay fallback. 003-B04, 003-E05, 003-H04, 003-H14, 003-I01–003-I09.                                                                                                                        |
| [DD05: Consumption and verification](../design-decisions/05-consumption-and-verification.md) | Whole groups claimed once at selection; usage differs from completion; retention precedes sink; immutable reports have no test outcome; later diagnostics remain separately inspectable. 003-B02, 003-B04, 003-B08, 003-E05–003-E06, 003-J01–003-J03. DD15 supersedes the old example of persisted clock sleeps. |
| [DD06: Stable conversion](../design-decisions/06-runtime-to-snapshot-conversion.md)          | Reserve order and needed time at observation; detach native values in their valid isolation; preserve live results on late conversion failure and refuse unhealthy publication. 003-B02–003-B04, 003-C06, 003-G08, 003-I01–003-I08.                                                                          |
| [DD07: Persistence](../design-decisions/07-persistence-boundary.md)                          | Optional at the core; load once; replace whole healthy candidates; preserve untouched baseline tracks; logical atomicity and last writer wins. 003-C01–003-C07, 003-H07.                                                                                                                         |
| [DD08: Schema compatibility](../design-decisions/08-schema-compatibility.md)                 | Independent positive envelope/system versions, explicit registration, strict first-party fields, deterministic JSON, no POC importer. 003-C01–003-C04, 003-F02, 003-G03, 003-H02–003-H13.                                                                                                                    |
| [DD09: Preparation](../design-decisions/09-normalization-and-redaction.md)                   | Structural canonicalization, redaction, normalization, validation before admission, including decoded input and resources. Immutable setup policy; match projection is separate. 003-B02, 003-C02, 003-G06, 003-H03–003-H04, 003-H07–003-H08.                                                                    |
| [DD10: Lifecycle](../design-decisions/10-lifecycle-and-ownership.md)                         | Immutable definitions, fresh executions, ordered activation and reverse rollback, explicit idempotent finish, body outcome plus final report, quiescence, lightweight post-finish reporter independent of execution resources. 003-B02–003-B03, 003-B08–003-B09, 003-C04–003-C06, 003-E03, 003-G09, 003-I08.             |
| [DD11: HTTP domain](../design-decisions/11-http-model-strategy.md)                           | HTTP Types currency only in optional HTTP products; Diorama owns fields, bodies, policies, schema; native semantics remain in adapters. 003-H01–003-H14.                                                                                                                                     |
| [DD12: URLSession](../design-decisions/12-urlsession-scope.md)                               | Per-session interception, supported HTTP(S) data tasks, early rejection in all modes, redirects and Basic/Digest, tested platform profiles. 003-D01–003-D05, 003-I01–003-I09; ordering gate Q1 applies.                                                                                              |
| [DD13: Random](../design-decisions/13-random-proving-system.md)                              | Reference-semantic generator, ordered raw UInt64, no timestamps, injected live source, zero after diagnosed exhaustion, public-only implementation. 003-B01–003-B08, 003-C07.                                                                                                                    |
| [DD14: Scheduler](../design-decisions/14-real-time-replay-scheduler.md)                      | One execution-owned ContinuousClock, one-to-one delays, deterministic handoff, no registration reentrancy, atomic cancel/claim, delivery acknowledgement. 003-E01–003-E08; availability gate Q2 applies.                                                                                     |
| [DD15: Clock](../design-decisions/15-clock-system.md)                                        | Millisecond wall origins and signed successive deltas; positional overrides; empty wall payload; nonpersisted monotonic Clock. 003-F01–003-F07.                                                                                                                                              |
| [DD16: Location](../design-decisions/16-location-system.md)                                  | Portable async replay, origin-relative WGS84 measurements, separate delivery time, access barriers, nonterminal failures, narrow Apple facade. 003-G01–003-G09.                                                                                                                              |
| [DD17: HTTP composition](../design-decisions/17-http-lifecycle-composition.md)               | One recursive tree, embedded typed supplements, exact bodies once, weighted delivery, conditional derived length, local delays and timing-only override merge. 003-H05–003-H14, 003-I01–003-I09.                                                                                                     |
| [Overview](../design-overview.md)                                                            | Ignoring an attachment changes verification only: it never bypasses persistent registration, preparation, or schema validation. 003-C01–003-C06, 003-J03.                                                                                                                                        |
| [Dependency policy](../dependency-policy.md)                                                 | Candidate status is not adoption approval. Tools and HTTP products need exact reviewed adoption records before use. 003-A02, 003-H01, and any later demonstrated need.                                                                                                                       |
| [Quality policy](../quality-gates-and-ci.md)                                                 | One complete tooling/CI bootstrap review unit, warning-free strict concurrency, all applicable platforms, required Codecov uploads. 003-A01–003-A04, 003-B10, every subsequent code unit.                                                                                                        |

Further interpretations that must survive implementation:

- Stable track order does not impose global call order.
  A canceled, open, or partially delivered claim remains used and never returns to availability.
- First-party error metadata explicitly permitted to be omitted by DD16/DD17 warns without poisoning a recording.
  Other failed preparation does poison it.
  Neither path replaces live native behavior when it can still be forwarded.
- Unsupported URLSession tasks are rejected early even in passthrough.
  That differs from an unexpected unrepresentable value observed after a supported live operation has begun.
- DD17 refines HTTP timing: persist successive local delays, exclude caller decision latency, and start a continuation's delay when the current decision returns.
  For example, a 100ms continuation waits 100ms after that decision; it does not become immediately due merely because the decision was slow.
  DD14's general deadline-plus-prerequisite mechanism must support that mapping.
- DD17 supplies HTTP correspondence for repeated equivalent requests by stable occurrence order.
  Unresolved correspondence outside that rule must not move overrides silently.
  Clock positional and location origin-only merge policies remain distinct; do not impose a universal merge algorithm.
- Live capture and replay share a monotonic source and rate, but serve separate roles.
  Replay delivery cannot determine when a native observation was captured.

## Unresolved gates and evidence-dependent choices

These entries retain resolved review questions alongside choices awaiting implementation evidence.
Q1–Q3 have owner-approved resolutions; Q4–Q5 remain gated at their named units.
Record further owner resolutions in a decision/amendment or policy as appropriate, then update the affected units.
A failed spike stops the affected branch of work; it is not permission to narrow an accepted contract or silently change APIs.

### Q1 — URLProtocol evidence versus production task division (resolved by owner, 2026-09-06)

The owner approved provisional production task planning before the interception spikes run.
Before production work depends on the proposed `URLProtocol` boundary, the spike results must be reviewed and the affected task breakdown confirmed or revised.
Evidence contradicting accepted behavior requires reopening the affected decision.
This is recorded in [DD12's planning-order clarification](../design-decisions/12-urlsession-scope.md#planning-order-clarification--2026-09-06).

003-D01–003-D05 cover all six required spike questions.
The H/I production breakdown can therefore be reviewed now and remains provisional until 003-D05 confirms or revises it against the evidence.
The required URLSession capabilities are unchanged.
Resolving Q1 did not itself approve the plan or execute a spike; plan approval was recorded separately on 2026-09-07.

### Q2 — Apple clock availability (resolved by owner, 2026-09-06)

The original quality policy required iOS 15; DD14 requires `ContinuousClock`, and DD15 requires Swift `Clock` conformance.
The installed Apple SDK's `_Concurrency.swiftinterface` marks both APIs as available from iOS 16 and macOS 13.
The upstream [Clock](https://github.com/swiftlang/swift/blob/main/stdlib/public/Concurrency/Clock.swift) and [ContinuousClock](https://github.com/swiftlang/swift/blob/main/stdlib/public/Concurrency/ContinuousClock.swift) declarations also carry standard-library availability requirements.

The owner approved raising the minimum to iOS 16 and the equivalent Apple platform releases.
The delivery policy now sets iOS/iPadOS 16 and macOS 13; equivalent availability floors are tvOS 16, watchOS 9, Mac Catalyst 16, and visionOS 1 if those platforms are separately supported.
This does not expand the initial macOS/iOS/Linux support matrix or override DD12's watchOS exclusion.
003-A01 must verify these minima with the selected toolchain, including the
owner-approved beta bootstrap exception recorded on 2026-09-07.
No substitute clock or further availability increase is authorized by this resolution.

### Q3 — Diagnostics after an immutable final result (resolved by owner, 2026-09-06)

The owner approved a small, separately retained diagnostic reporter.
`finish()` freezes one immutable result, and repeated calls return that result.
Later misuse of escaped dependencies enters a separately inspectable log, whether or not a sink is installed.
Any configured sink is notified afterward.
These facts do not reopen the execution ledger or alter the returned report.

Escaped dependencies retain only reporting context and their required frozen state, not sessions, scheduling machinery, recordings, or live sources.
The reporter has no global registry and is released with its remaining owners.
New misuse reporting does not restart execution or schedule replay callbacks.
Testing integrations must respect their test context's lifetime; retention does not retroactively change a completed test.

The accepted contracts are recorded in [DD05](../design-decisions/05-consumption-and-verification.md#post-finish-diagnostic-retention--2026-09-06) and [DD10](../design-decisions/10-lifecycle-and-ownership.md#post-finish-reporting-lifetime--2026-09-06).
003-B02/003-B03 implement the reporting and ownership boundary; 003-B08 verifies the concurrent freeze boundary and unchanged final result.
Startup rollback failures continue to use DD10's structured startup result before an execution exists.
Resolving Q3 did not itself approve the plan; plan approval was recorded separately on 2026-09-07.

### Q4 — Stable geographic mapping and bounded native error data

DD16 specifies WGS84 origins and east/north meters but leaves the mapping algorithm, constants, singularities, and useful numerical error bounds to be fixed as part of the stable codec.
003-G02 supplies independent numerical evidence and a proposed contract before 003-G03 encodes it.
A choice that changes the accepted local/regional route semantics needs owner resolution, not an improvised projection or unapproved geodesy dependency.

DD12/DD16/DD17 likewise leave exact safe user-info allowlists and recursive bounds to implementation review.
003-G01/003-G03 and 003-H09 must document these before native capture depends on them.
Field omissions already permitted by the decisions are not new permission to discard other behavior.

### Q5 — Delivery selections still to be recorded

003-A01 selects exact Swift/Xcode versions at bootstrap under the owner-approved beta exception, the macOS CI host, iOS simulator destination, and Linux distribution, architecture, official Swift toolchain/container, and libcurl version.
Record how libcurl is fixed or bounded and revalidated.
Selections and remaining verification gaps are tracked in
[003-A01's evidence](../evidence/003-A01-toolchain-and-availability.md).
No floating “latest” value in this plan is a version pin.
003-A02 fixes tool adoptions, 003-H01 fixes HTTP package adoption, and 003-B10 confirms numeric coverage thresholds against real coverage.
Codecov authentication/account configuration must be available for 003-A04's required uploads; lack of it is a reported gate, not a reason to weaken CI.

Public Swift names, file layout, synchronization primitives, JSON key spelling, resource layout, scalar rounding tie rules where unspecified, and test-framework adapter APIs are reviewable implementation choices within accepted semantics.
Use the smallest needed design and document it in the owning unit.
Do not add speculative public protocols, dependencies, or future-feature switches.

## Review and commit protocol (R)

Every unit below has its own stopping point.
Phases group related outcomes; they do not authorize a batch of work or combine branches.

1. Start each unit by stating its full identifier, recommended Codex model and reasoning effort, and a brief reason, using its recommendation below as the starting point.
   Preliminary read-only inspection may refine the recommendation against current prerequisites, evidence, and available models.
   Wait for explicit owner confirmation of the model and reasoning effort before implementation or running the unit's experiments.
   Include the intended scope in the same request where possible so one confirmation covers both; an earlier instruction to select or commence a unit is not confirmation of an as-yet unstated recommendation.
2. Confirm that the plan and selected unit are authorized, its prerequisites are reviewed, and its gates are resolved.
   Inspect branch and worktree; use one feature branch for that review unit and preserve unrelated changes.
   If scope was not included in step 1's confirmation, summarize the intended work and wait for explicit owner confirmation before proceeding.
   The owner may adjust either scope or model settings at this checkpoint; do not repeat a confirmation already given for the same scope and settings.
3. Implement only its bounded outcome and needed tests/documentation.
   Expected paths below are proposed ownership, not instructions to create empty targets or future public APIs.
   Add targets when the first real capability needs them.
4. Break the implementation into smaller atomic commits when possible and useful.
   Decide the split during implementation.
   Each proposed commit should explain one coherent change and retain a usable, verifiable baseline; avoid separating a behavior from the tests that prove it.
5. Once the unit's scope is confirmed, create atomic commits and amend, rebase, or otherwise rewrite its feature-branch history as useful, including published history, without per-commit approval.
   Explicit instructions to leave work uncommitted and dependency approval stops still apply.
   Never edit or commit directly on, or rewrite the history of, `master` or `main`; preserve unrelated and concurrent work.
   Pushing rewritten history follows the authorization boundary in step 8.
6. Run focused verification, then the applicable review gate below.
   Present the complete feature-branch diff against its base branch, including any uncommitted changes, rather than only the working-tree diff.
   The review request must describe behavior, files, the actual commit breakdown (and any remaining proposed commits), evidence, limitations, dependency changes, and unresolved design questions.
7. Stop for owner review.
   Address feedback and rerun verification checks.
8. After the owner approves PR creation, push the feature branch and create a GitHub Pull Request.
   This approval authorizes the initial push and subsequent branch updates for the same review unit, including rewritten published history; before approval, remote changes require separate authorization.
   Use `--force-with-lease` for rewritten history, inspecting remote state and preserving concurrent work before pushing.
   Update the unit/plan status and relevant documentation in the PR that effects this status change such that merging it will produce the correct status on `master`.
   Do not convert a draft or partial milestone into an approved or complete one.
9. Merge the PR only after required CI passes for the revision being merged and the owner separately and explicitly requests the merge.
10. Do not begin another review unit without explicit owner instruction; PR creation, passing CI, and merge approval do not authorize continuation.

### Codex model and reasoning guide

Reviewed on 2026-09-07 for all 76 remaining units, 003-A02 through 003-J04.
The recommendations are engineering estimates based on each unit's scope, prerequisites, verification burden, and cost of a missed invariant; they are not benchmark results or measured token budgets.
They deliberately allow some extra capability and reasoning depth, especially for public API foundations, concurrency, persistence atomicity, and native platform uncertainty.
003-A01 is already complete and receives no retrospective recommendation.

The [official model guide](https://learn.chatgpt.com/docs/models#choosing-astra-sol-terra-and-luna) distinguishes Astra for the hardest end-to-end work, Sol for complex work, Terra for everyday work, and Luna for clear, repeatable tasks.
Its [reasoning guide](https://learn.chatgpt.com/docs/models#pick-a-reasoning-effort) describes medium as a balance and high/extra high for difficult work.
The per-unit assignments below are this repository's judgment, not OpenAI recommendations for Diorama.

| Model | Identifier | Use in this plan |
| --- | --- | --- |
| GPT-5.6 Terra | `gpt-5.6-terra` | Bounded setup, adoption records, established replay patterns, and coverage-policy evidence. |
| GPT-5.6 Sol | `gpt-5.6-sol` | Most implementation units with defined contracts but meaningful schema, isolation, or integration work. |
| GPT-6 Astra | `gpt-6-astra` | Difficult state machines, shutdown proofs, numerical contracts, and work combining several sensitive boundaries. |

Each unit names one model and one effort for the complete unit, including its proving tests and self-review.
`medium`, `high`, and `xhigh` are the effort identifiers; `xhigh` means Extra High in the picker.
Luna is useful for mechanical follow-up edits, but is not the recommended primary model for these units given their cross-platform and review obligations.
Max and Ultra are not baseline recommendations: these are deliberately bounded units, and greater effort or delegation is not automatically better value.

Use these recommendations as starting settings, not permanent model pins or promises of availability.
At each unit's initial checkpoint, verify that the selected client offers the named model/effort, explain any proposed substitution, and let the owner select the settings; do not silently change models or claim to have changed the active session's settings.
Reassess later estimates when earlier evidence changes the work, especially after 003-D05 and 003-G02.
If implementation exposes a materially harder problem or repeated inconclusive attempts, explain the gap and propose a revised model/effort for confirmation before continuing that work.
Model selection never resolves an architectural conflict or bypasses a dependency approval gate.

For token value, keep the relevant decisions, scope, and focused failure evidence in context and avoid repeating successful checks without a new reason.
Consider total effort including retries, not just per-token price; no fixed savings or token counts are assumed here.
Use completed units to calibrate later recommendations with the owner while retaining the conservative margin.

### Verification gates

- **V-doc:** Check local links, references, status consistency, and whitespace with `git diff --check` across the complete proposed change, not only uncommitted edits; inspect the complete branch diff against its base, including any uncommitted changes. Documentation and adoption units report evidence without pretending to have run implementation tests.
- **V-spike:** V-doc plus the isolated executable experiment and its platform matrix. Record exact commands, toolchain/runtime versions, observed outcomes, unanswered cases, and a reproducible findings note. Spikes have no production imports or dependency additions. Experimental packages do not become an accepted implementation or implicit dependency approval.
- **V-code:** Focused tests, then canonical non-mutating `scripts/check` (or the names selected in 003-A04). Formatting, strict lint, debug/release builds, Swift 6 complete concurrency checking, and host tests must pass. Required macOS, iOS Simulator, and Linux jobs, with applicable products and coverage, must pass before the unit becomes an accepted integration baseline. Obtain CI evidence through the owner's authorized PR workflow; approval to implement or review a unit does not itself authorize remote changes. After branch updates or history rewrites, verify required CI passes for the revision being merged.
- Missing environments, credentials, simulators, or CI runs are explicitly reported as unverified.
  Do not substitute macOS `swift test` for iOS execution, accept a skipped required job, or claim that compilation proves native callback behavior.
  Stop at review with the exact remaining evidence.
- Every first public surface has documentation checks and strict concurrency.
  Warnings fail the gate.
  Any unsafe sendability/isolation, broad availability, detached-task, or warning exception needs a documented, reviewed invariant and focused evidence; it is not a routine way to get checks green.
- Schema work adds committed canonical fixtures, malformed/unknown-field and version rejection, allowed editing-form normalization, and semantic assertions.
  Preserve readers/fixtures for every publicly released schema in the package major series; do not fabricate historical readers before such schemas exist.
- Native systems add record/replay/passthrough, offline failure, cancellation, post-finish, and resource-ownership evidence for each newly supported surface.
  Later conformance units broaden those cases; they never defer basic safety.
- Tests must make meaningful behavioral assertions.
  Use controlled dependencies, internal test clocks, and deterministic handoff observations for races; small real-clock tests use tolerant elapsed bounds, never exact task ordering.

## Phase map and proposed ownership

| Phase | Review units | Milestone                                                                    |
| ----- | ------------ | ---------------------------------------------------------------------------- |
| A     | 003-A01–003-A04      | Toolchain/approval evidence, minimal package, complete quality bootstrap.    |
| B     | 003-B01–003-B10      | Public sequential core and an in-memory random system.                       |
| C     | 003-C01–003-C07      | Persisted random and consumer-defined systems; first complete vertical path. |
| D     | 003-D01–003-D05      | Isolated URLProtocol evidence and reviewed native capability boundaries.     |
| E     | 003-E01–003-E08      | Shared real-time scheduler and reusable grouped behavior services.           |
| F     | 003-F01–003-F07      | Complete portable clock system.                                              |
| G     | 003-G01–003-G09      | Portable location replay and narrow Apple live/delegate integration.         |
| H     | 003-H01–003-H14      | Shared HTTP domain, resource publication, strict URLSession lifecycle data.  |
| I     | 003-I01–003-I09      | Incremental production URLSession conformance across platform bridges.       |
| J     | 003-J01–003-J04      | Opt-in test integrations, combined-system acceptance, user documentation.    |

Default order follows the table, one unit at a time.
Explicit prerequisites identify independent work the owner may choose to reorder; they do not authorize parallel agent work or automatic continuation.
Under resolved Q1, the provisional HTTP/URLSession production breakdown is confirmed or revised against reviewed spike evidence at 003-D05 before production work depends on that boundary.

Proposed products are `DioramaCore`, `DioramaRandom`, `DioramaClock`, `DioramaLocation`, `DioramaHTTP`, and `DioramaURLSession`.
Optional persistence, Core Location, XCTest, and Swift Testing code belongs in suitable separate targets/products when introduced.
Names such as `DioramaPersistence`, `DioramaCoreLocation`, `DioramaXCTest`, and `DioramaTesting` below are working labels.
They do not impose a new architectural commitment.
Core must compile without HTTP Types, test frameworks, or Apple-only adapters.
Linux builds the portable location model/replay, not a fictitious live location provider.

`Sources/<module>/`, `Tests/<module>Tests/`, and their fixture directories are the expected paths for a named module below.
Add only relevant `Package.swift` entries, documentation, and CI coverage classification with each new target.
Use `Spikes/<topic>/` and `docs/evidence/<topic>.md` for isolated experiments; neither path exists merely because it appears in this plan.

## Phase A — Delivery foundation

### 003-A01 — Toolchain and deployment feasibility record

- Status: Complete; owner confirmed scope and the installed beta toolchain on 2026-09-07.
- Prerequisites: Plan authorization; quality policy, DD14–DD16, Q2/Q5.
- Scope: Identify exact toolchains and platform matrix under the owner-approved 2026-09-07 beta bootstrap exception; verify clock availability at the newly approved deployment minima from Q2.
- Expected files/modules: `docs/evidence/003-A01-toolchain-and-availability.md`; isolated availability probes under `Spikes/ToolchainAvailability/`.
- Public behavior: No library surface; a reviewable statement of which APIs can run on each minimum platform, separate from the CI runtime versions.
- Tests/verification: V-spike; Swift 6 compile probes at iOS 16/macOS 13, toolchain feature support, macOS/Linux compatibility evidence.
- Exclusions: Package-wide availability increases, substitute clocks, runtime architecture, installing production dependencies, and prerelease toolchains outside the owner-approved bootstrap exception.
- Checkpoint: R; stop with pins and minimum-runtime evidence.
  Surface any newly discovered availability conflict without broadening Q2's approved change.

### 003-A02 — Quality-tool adoption records

- Status: Complete; owner confirmed scope and GPT-5.6 Terra at `high` reasoning, then approved the tool and action records, on 2026-09-07.
- Recommended model: GPT-5.6 Terra; reasoning: `high`. Tool adoption and pin review span several sources and platform constraints, but add no runtime architecture.
- Prerequisites: 003-A01; dependency and quality policies.
- Scope: Propose exact Mint, SwiftFormat, and SwiftLint adoptions and review the URITemplate configuration baseline and planned GitHub Actions sources/pins.
- Expected files/modules: Adoption entries in `docs/dependency-policy.md` and [003-A02 tooling evidence](../evidence/003-A02-quality-tool-adoptions.md); no Mintfile or production manifest dependency yet.
- Public behavior: No runtime change; explicit reproducible tool approval unit.
- Tests/verification: V-doc; exact repository, identity, products/executable, version/major rule, purpose, alternatives, direct/transitive graph, license, maintenance, toolchain/platform impact, and reviewed action SHAs.
- Exclusions: Speculative algorithms packages, DocC grandfathering, silent tool installation, approval inferred from “approved candidate.”
- Checkpoint: R plus explicit dependency approval; stop before any tooling declaration requires the proposed packages.

### 003-A03 — Minimal package skeleton

- Status: Complete; owner confirmed scope and GPT-5.6 Terra at `medium` reasoning on 2026-09-07.
- Recommended model: GPT-5.6 Terra; reasoning: `medium`. A minimal manifest and test target follow the already recorded toolchain and deployment selections.
- Prerequisites: 003-A01 and resolved deployment selections; quality policy.
- Scope: Establish only the package and minimal test target needed by bootstrap.
- Expected files/modules: `Package.swift`, minimal `Sources/DioramaCore/` and `Tests/DioramaCoreTests/`, relevant `.gitignore`, and [003-A03 package evidence](../evidence/003-A03-package-skeleton.md).
- Public behavior: No placeholder public API or runtime architecture.
- Tests/verification: Minimal build/test on selected hosts, Swift 6 complete concurrency and iOS deployment compile check; V-doc.
  Record pending 003-A04 gates.
- Exclusions: System protocols, scenario execution, persistence, random, HTTP, third-party library dependencies, copying the POC package structure.
- Checkpoint: R; review only the buildable skeleton.
  Feature work waits for 003-A04.

### 003-A04 — Canonical quality and CI bootstrap

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Coordinate SwiftPM, Xcode, Linux, coverage, and intentional failure checks through one reproducible quality gate.
- Prerequisites: 003-A02 adoption approval, 003-A03, quality policy, Q5 configuration.
- Scope: Deliver the complete policy bootstrap as one review unit, permitting smaller reviewed commits internally.
  Establish formatting, lint, tests, debug/release strict builds, platform CI, coverage, and update automation.
- Expected files/modules: `Mintfile`, `.swiftformat`, `.swiftlint.yml`, `scripts/{format,lint,test,check}`, coverage helper, `.github/workflows/`, `.github/dependabot.yml`, `.codecov.yml`, internal developer setup instructions in `README.md`.
- Public behavior: One canonical local/CI gate; format applies fixes, checks do not.
  Missing Mint prints explicit installation guidance.
  Public-doc lint begins with the first public declarations; overlapping tool rules are resolved.
- Tests/verification: V-code bootstrap on macOS/iOS Simulator/Linux; intentional format, lint, warning, build/test, and upload failures fail their stage.
  Coverage uses discovered SwiftPM/Xcode output and separate `macos`, `ios`, `linux` flags, requiring every upload and making upload failure fatal.
- Exclusions: Runtime architecture, tool dependencies in library targets, assertion-free coverage padding, invented final thresholds before 003-B10.
- Checkpoint: R; require complete bootstrap evidence before 003-B01.
  Review exact toolchain pins, SHA-pinned actions with version comments, least permissions, superseded-run cancellation, platform/toolchain/manifest cache keys, weekly SwiftPM/Actions Dependabot, and weekly/manual `mint outdated` reporting.

## Phase B — Sequential core and random

### 003-B01 — Typed scenario definitions and track identity

- Recommended model: GPT-5.6 Sol; reasoning: `high`. The first public generic identity and configuration boundary must support heterogeneous non-Codable systems without speculative APIs.
- Prerequisites: 003-A04; DD01–DD04, DD10, DD13.
- Scope: Define immutable scenario configuration, ordered attachment/track identity, default/whole-system modes, and typed in-memory sequential content.
- Expected files/modules: `DioramaCore` definition, identity, mode, and track value files; focused tests and public API documentation.
- Public behavior: Heterogeneous record types and repeated system instances coexist under unique keys; stable system type, attachment, track, and record identity are distinct.
  Stable values need not be Codable.
- Tests/verification: V-code; duplicate/incompatible identity rejection, deterministic order, effective modes, empty valid content, non-Codable types.
- Exclusions: Mutable execution, scheduling, JSON, generic metadata bags, HTTP-specific inputs, persistence identity inferred from Swift type names.
- Checkpoint: R; stop to review the smallest typed data/configuration boundary.

### 003-B02 — Prepared admission, safe diagnostics, and health

- Recommended model: GPT-6 Astra; reasoning: `high`. Prepared admission, reentrant sinks, secret exclusion, and reporter ownership establish several interacting invariants.
- Prerequisites: 003-B01; DD05–DD06, DD09–DD10; resolved Q3 reporting contract.
- Scope: Establish safe structured diagnostics, retention-before-sink delivery, a separately retained reporter, prepared admission, and recording-health facts.
- Expected files/modules: `DioramaCore` diagnostics/reporter, preparation boundary, and health types; consumer transform and failing-sink tests.
- Public behavior: Systems submit only prepared values; sinks cannot suppress ledger entries.
  Infrastructure facts remain separate from dependency errors and test outcomes.
  The post-finish log is inspectable without a sink or retained execution; startup failures carry their own structured diagnostics.
- Tests/verification: V-code; concurrent/reentrant sink safety, deterministic context/order, concurrent reporter inspection with and without a sink, secret-marker exclusion, preparation failure health, no raw value rendered when conversion or transformation fails.
- Exclusions: Reflection sanitizers, universal native codec, first-party domain redaction rules, test-framework imports, changing a frozen final report.
- Checkpoint: R; review the reporter API, safe admission, and callback isolation.

### 003-B03 — Execution activation and sequential lease lifetime

- Recommended model: GPT-6 Astra; reasoning: `high`. Activation rollback and escaped-lease resource release define the execution ownership foundation.
- Prerequisites: 003-B01–003-B02; DD10, DD13; resolved Q2/Q3 contracts.
- Scope: Start fresh in-memory executions, prepare before activation, activate in attachment order, roll back in reverse order, and close sequential leases.
- Expected files/modules: `DioramaCore` execution, system registration and lease lifecycle files; controlled test adapters.
- Public behavior: No partial execution escapes; two starts share no mutable state.
  Basic explicit asynchronous finish closes admission and returns a retained result without relying on deinit.
  Escaped leases keep only reporting context and required frozen state after closure, not execution machinery.
- Tests/verification: V-code; failed preparation/activation, reverse cleanup, consumer ownership, fresh execution state, sequential use after lease closure, source/lease resource release while the reporter remains retained.
- Exclusions: Native adapters, repositories, timers, public asynchronous lifecycle scaffolding unrelated to the sequential proving system.
- Checkpoint: R; review execution ownership and the first usable public leases.

### 003-B04 — Atomic public sequential record and replay operations

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Atomic claims and reservation-before-preparation require explicit synchronization and deterministic race tests.
- Prerequisites: 003-B03; DD04–DD06, DD13.
- Scope: Add ordered append and single-use next-record claims through typed public leases, with reservation before potentially slow preparation.
- Expected files/modules: `DioramaCore` sequential track operations and ledger; concurrent operation tests.
- Public behavior: Record order follows observation/serialized admission, not conversion completion; replay claims once atomically.
  Closed or wrong-mode use and exhaustion diagnose; passthrough does not touch track content.
- Tests/verification: V-code; racing claims, out-of-order preparation completion, failed admission, independent attachments, no reuse, stable requested position.
- Exclusions: Domain matching, lifecycle trees, timing, reusable/cardinality policies, coupling all sources through a global random-source lock.
- Checkpoint: R; review synchronization and any documented sendability exception.

### 003-B05 — Consumer-module extension proof

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Public-only consumer proof may expose foundational API gaps that require narrow, carefully reviewed corrections.
- Prerequisites: 003-B04; DD02, DD13.
- Scope: Implement a test-only synchronous system from a distinct module using only public registration, mode, typed track, diagnostics, and lifetime APIs.
- Expected files/modules: Separate consumer test-support target and conformance tests; minimal core corrections only if demonstrated by this proof.
- Public behavior: Consumer systems can attach several named instances and record/replay non-Codable stable values without privileged access.
- Tests/verification: V-code; ordinary imports without `@testable`/SPI in the consumer target, all modes, independent keys, unused facts and closure.
- Exclusions: A shipped example system, random implementation, persistence, arbitrary replacement behavior engines, broad public protocol expansion.
- Checkpoint: R; stop on any public-boundary gap before first-party systems grow.

### 003-B06 — Random live recording and passthrough

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Serialize live source access with recording while preserving reference semantics and independent attachments.
- Prerequisites: 003-B05; DD13, DD06, DD09.
- Scope: Add the first-party reference-semantic RandomNumberGenerator using only the public extension boundary and an injected live source.
- Expected files/modules: `DioramaRandom`, its target/tests, documented injection example; only demonstrated core fixes.
- Public behavior: Default live source is SystemRandomNumberGenerator; source read and append serialize together.
  References share one attachment cursor; separately keyed attachments are independent.
  Record stores UInt64, no time.
- Tests/verification: V-code; known source sequence, reference sharing, live return values, passthrough zero track access, multiple sources, closed handles.
- Exclusions: Replay implementation (explicitly unavailable until 003-B07), seeds, distributions, cryptographic claims, clocks and native adapters.
- Checkpoint: R; review public-only implementation and source ownership.

### 003-B07 — Random replay and deterministic failure

- Recommended model: GPT-5.6 Terra; reasoning: `high`. Replay follows established public claims; source isolation and concurrent exhaustion still need careful proving tests.
- Prerequisites: 003-B06; DD05, DD13.
- Scope: Consume recorded raw values and implement exhaustion/lifecycle policy.
- Expected files/modules: `DioramaRandom` replay path and mode tests.
- Public behavior: Replay never initializes or calls the live source.
  Exhaustion emits a serious diagnostic and returns zero only if the handler returns; post-finish calls diagnose distinctly and remain offline in every mode.
- Tests/verification: V-code; zero/max UInt64, empty/exhausted sequence, unused values, counting/trapping source factory, repeat calls, handler notification, independent executions and concurrent consumption without duplicate claims.
- Exclusions: Looping, last-value reuse, manual rewind, deterministic assignment of values to uncoordinated racing tasks.
- Checkpoint: R; review the first complete in-memory random behavior.

### 003-B08 — Concurrent finalization and report evaluation

- Recommended model: GPT-6 Astra; reasoning: `xhigh`. Canceled waiters, one shared finish result, reporter lifetime, and racing diagnostics require a complete shutdown argument.
- Prerequisites: 003-B07; DD05, DD10, DD13; resolved Q3 contract.
- Scope: Complete sequential execution finalization, immutable usage/health/ cleanup reports, deterministic rendering, and explicit evaluation helpers.
- Expected files/modules: `DioramaCore` finalization/report/evaluation files; core and random lifecycle tests.
- Public behavior: Concurrent finish requests share one eventual result; waiter cancellation does not abandon cleanup.
  Results have no pass/fail flag and are not discardable.
  Later diagnostics remain separately inspectable and do not alter that result.
  Whole-scenario/attachment evaluation is explicit.
- Tests/verification: V-code; repeated/concurrent/canceled finish, cleanup failure continuing later cleanup, unused values, unattached/ignored facts, safe deterministic reports, unchanged repeated results after late misuse, diagnostics racing result freeze without loss or duplication, inspection after execution release, reporter release when its remaining owners release it.
- Exclusions: Timed callback quiescence (003-E03), file publication (003-C05), implicit XCTest/Swift Testing failures, deinit-driven correctness.
- Checkpoint: R; review lifecycle completion before extending the execution.

### 003-B09 — Scoped execution convenience

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Scoped cancellation must preserve both body and finalization outcomes without accidentally changing publication intent.
- Prerequisites: 003-B08; DD10.
- Scope: Wrap explicit execution in an async scope preserving body and finish outcomes, with publication intent carried to later repository integration.
- Expected files/modules: `DioramaCore` scoped helper, cancellation/error tests, public lifecycle examples.
- Public behavior: Always finalize on return, throw, or cancellation; suppress requested publication by default after body failure, with the explicit accepted opt-in policy.
  Neither outcome silently masks the other.
- Tests/verification: V-code; body success/error/cancellation, failing cleanup, canceled waiter, explicit versus scoped intent, source/result diagnostics.
- Exclusions: Test-framework hooks, inferring test failure from a sink, durable writes before 003-C05, new publication modes beyond DD10.
- Checkpoint: R; review ergonomic API and both-outcome error presentation.

### 003-B10 — First production coverage baseline

- Recommended model: GPT-5.6 Terra; reasoning: `medium`. Evaluate actual coverage reports and exclusions against an established policy without inventing thresholds.
- Prerequisites: 003-B08–003-B09 and 003-A04 platform uploads; quality policy, Q5.
- Scope: Confirm exact project tolerance and patch coverage settings from the first meaningful core/random baseline, retaining every platform upload.
- Expected files/modules: `.codecov.yml`, coverage-policy evidence and concise quality documentation update.
- Public behavior: No library change; concrete regression/reporting thresholds proposed for owner confirmation.
- Tests/verification: V-doc and actual macOS/iOS/Linux coverage status evidence; review exclusions, previous-commit baseline, patch report, incomplete uploads.
- Exclusions: Invented coverage targets, disabling failing tests/uploads, generated assertions to inflate coverage.
- Checkpoint: R; stop for threshold confirmation before wider feature coverage.

## Phase C — Optional persistence and the first complete vertical path

### 003-C01 — Persistent-system registration and version dispatch

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Typed heterogeneous dispatch and optional persistence registration shape a lasting public extension boundary.
- Prerequisites: 003-B08; DD07–DD09.
- Scope: Add the optional Codable registration boundary, stable system type identity, positive integer envelope/payload versions, and supported readers.
- Expected files/modules: `DioramaPersistence` registry/codec boundary and tests; minimal explicit core connection for optional persistence.
- Public behavior: In-memory non-Codable systems still work.
  Publication requires registration for every included track; ignored/unattached payloads are not exempt.
  Unknown type, incompatible registration, and version differ.
- Tests/verification: V-code; heterogeneous dispatch, repeated system instances, duplicate registrations, unknown/unsupported versions, nonpersistable refusal.
- Exclusions: JSON storage, migrations for nonexistent public schemas, opaque preservation of unknown systems, silently dropping ephemeral tracks.
- Checkpoint: R; review registration independently from file I/O.

### 003-C02 — Deterministic version-one JSON and random schema

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Deterministic cross-platform JSON, full UInt64 precision, and strict schema rejection need independent fixture evidence.
- Prerequisites: 003-C01, 003-B07; DD08–DD09, DD13.
- Scope: Encode/decode the envelope and random payload deliberately; validate strict first-party keys and prepare loaded values before admission.
- Expected files/modules: `DioramaPersistence` JSON codec, random persistence registration, canonical/rejection fixtures and schema documentation.
- Public behavior: Pretty UTF-8 JSON has deterministic object keys, semantic array order, trailing newline, no volatile metadata, explicit version 1.
  Random UInt64 values retain full precision without incidental timestamps.
- Tests/verification: V-code; byte goldens across platforms, empty/max values, unversioned POC rejection, unknown nested keys, malformed data, safe paths, reader/writer checks against independent committed fixtures.
- Exclusions: Upstream synthesized schema as a contract, YAML, general metadata, resources, arbitrary coercion, adding Codable to the core requirement.
- Checkpoint: R; review human-readable schema and compatibility obligations.

### 003-C03 — Single-document atomic file repository

- Recommended model: GPT-6 Astra; reasoning: `high`. Atomic file replacement, failure preservation, and readers racing writers require platform-aware storage reasoning.
- Prerequisites: 003-C02; DD07–DD08.
- Scope: Implement repository location/load and staged atomic replacement for the first resource-free scenario; keep encoding separate from storage.
- Expected files/modules: `DioramaPersistence` file repository and storage boundary; temporary-directory integration tests and evidence.
- Public behavior: Missing, empty-valid, unreadable, invalid, and incompatible remain distinct.
  Readers see a complete old/new document; failed publication preserves the old file.
  Concurrent successful writers are last writer wins.
- Tests/verification: V-code; read-only replay access, failed encode/stage/commit, replacement/read races, abandoned staging cleanup, deterministic path rules on macOS/Linux and applicable iOS sandbox storage.
- Exclusions: Public flush, per-event durable append, locking for the duration of recording, optimistic revisions, multi-file publication before 003-H07.
- Checkpoint: R; review atomicity evidence and documented backend limitations.

### 003-C04 — Baseline loading before activation

- Recommended model: GPT-5.6 Sol; reasoning: `high`. The load-outcome and effective-mode matrix must prevent any live activation on unusable replay input.
- Prerequisites: 003-C03, 003-B03; DD07–DD10.
- Scope: Connect optional repository loading, preparation, and full validation to startup; retain exact load outcome and apply effective-mode policy.
- Expected files/modules: Core startup/persistence orchestration, repository tests with activation/source counters.
- Public behavior: Any replay requires a usable programmatic or loaded baseline before activation.
  Record-only rebuilding may ignore unusable stored input after diagnosing loss of overrides/unchanged tracks; that alone is not unhealthy.
- Tests/verification: V-code; missing versus empty, malformed/unsupported data, missing registration including ignored systems, mixed-mode refusal, zero adapter activation/live access on bad replay setup, untouched old destination.
- Exclusions: Treating invalid as empty, partial replay, live fallback, publication at startup, diagnosing mere unused data as a test failure.
- Checkpoint: R; review the full load-outcome/effective-mode table.

### 003-C05 — Complete candidate replacement and final publication

- Recommended model: GPT-6 Astra; reasoning: `high`. Combine mixed-mode candidate preservation, publication health, and exactly-once finalization without partial writes.
- Prerequisites: 003-C04, 003-B08–003-B09; DD07, DD10, DD13.
- Scope: Build and publish one finalized candidate; replace random record-mode tracks and preserve valid replay/passthrough/ignored/unattached baseline data.
- Expected files/modules: Core candidate/finalization orchestration and persistence integration tests, random file workflow examples.
- Public behavior: No replay/consumption writes; publication occurs only at finish when requested and healthy.
  Scoped body failure suppresses it by default; explicit finish follows configured intent.
  Record replaces, not appends.
- Tests/verification: V-code; mixed attachments, record-only rebuild, whole candidate health, preserved tracks, repeated finish publishes once, body success/throw/cancellation and explicit allow-after-failure policy.
- Exclusions: HTTP/clock/location override merge before those systems define it, partial healthy-track publication, recovery draft files, incremental flush.
- Checkpoint: R; review end-to-end load/run/finalize/publication ownership.

### 003-C06 — Publication failures and actionable reports

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Fault injection must distinguish committed publication from cleanup failures while retaining safe earlier diagnostics.
- Prerequisites: 003-C05; DD05–DD10.
- Scope: Complete report dispositions and stage-specific fault handling using injected storage, preparation, grouping, validation, and cleanup failures.
- Expected files/modules: Core/persistence reports and renderers; fault-injection tests and safe report goldens.
- Public behavior: Published/not-requested/unhealthy-refusal/encoding-storage failure remain programmatically distinct.
  Reports identify safe destination, stage, affected data, unpublished candidate summary, and preservation outcome.
- Tests/verification: V-code; live return preserved on conversion failure, ledger-before-sink at finalization, one unhealthy track blocks all writes, cancellation cannot abandon finalization, post-publication cleanup failure is reported without pretending to undo a committed publication.
- Exclusions: Raw native error dumps, automatic test outcomes, hidden partial success, loss of earlier diagnostics after a later failure.
- Checkpoint: R; review every refusal/failure disposition and prior-file evidence.

### 003-C07 — Persisted consumer-system and random conformance

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Public-only persistence and random integration prove the first complete vertical path across all platforms.
- Prerequisites: 003-C06, 003-B05–003-B07; DD13, DD07–DD08.
- Scope: Prove optional persistent registration from another module and complete random record-to-file-to-new-replay execution through public APIs only.
- Expected files/modules: Consumer conformance target, random/persistence integration fixtures and minimal documented registration example.
- Public behavior: A consumer system shares first-party facilities with no internal access; non-Codable in-memory use still has no persistence obligation.
- Tests/verification: V-code; two random plus heterogeneous consumer attachments, all modes, read-only replay, fresh cursors, unused/exhausted reports, repeated deterministic publication, public-only imports and concurrent source isolation.
- Exclusions: Scheduler, native adapters, new example packages/dependencies, general consumer behavior-engine replacement.
- Checkpoint: R; the first vertical milestone is complete only with full platform evidence.
  Stop before introducing scheduler or native-adapter complexity.

## Phase D — Isolated URLProtocol evidence

These are experiments, not a second implementation to promote into production.
The complete matrix answers DD12's six spike questions; a successful GET alone does not approve redirect, challenge, or rejection behavior.
Under resolved Q1, 003-D05 confirms or revises the provisional H/I breakdown against reviewed evidence before production work depends on the proposed boundary.

### 003-D01 — Bodyless GET interception and routing spike

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Establish controlled native interception and route isolation experiments across Apple Foundation and FoundationNetworking.
- Prerequisites: 003-C07, 003-A01; DD12, DD17, Q1.
- Scope: Prove per-session interception and routing for a bodyless GET, first on macOS and Linux, then an iOS simulator, using a controlled protocol/server.
- Expected files/modules: `Spikes/URLSessionInterception/` executable tests and `docs/evidence/urlsession-interception.md` with exact Swift/libcurl/runtime data.
- Public behavior: None; evidence for configuration-copying, isolated routes, self-interception prevention, and no live access in simulated replay.
- Tests/verification: V-spike; two sessions/executions, existing protocol order, cache disabling, absent/unknown/expired routing, reserved-field collision and stripping before forwarding, uninstrumented sessions unaffected.
- Exclusions: Production URLSession target, global registerClass, adopting POC routing, claiming full API/platform parity from source compatibility.
- Checkpoint: R; stop with pass/fail evidence per bridge before expanding scope.

### 003-D02 — Task rejection and response-presentation spike

- Recommended model: GPT-6 Astra; reasoning: `xhigh`. Unknown native rejection points and delegate surfaces can undermine the no-live-replay guarantee.
- Prerequisites: 003-D01; DD12 response/task/delegate sections, DD17.
- Scope: Determine reliable rejection points and data-task interception across URL/URLRequest, completion, delegate, async, and task-delegate forms.
- Expected files/modules: Isolated interception tests and findings matrix.
- Public behavior: None; identify which surfaces can be safely advertised.
- Tests/verification: V-spike; httpBody versus body streams, response heads and multiple chunks, allow/cancel/open disposition, unsupported task families, resume/conversion/non-HTTP operations, optional delegate detection, cache bypass prevention, and zero unintended network access on each bridge.
- Exclusions: Documenting a replay leak as an acceptable platform limitation, silently allowing unsupported operations in passthrough, production code.
- Checkpoint: R; stop if the native session boundary cannot enforce a required exclusion; reopen the smallest affected DD12 boundary before depending on it.

### 003-D03 — Redirect correlation spike

- Recommended model: GPT-6 Astra; reasoning: `xhigh`. Correlation across protocol instances, redirect decisions, and cross-origin preparation needs exploratory platform reasoning.
- Prerequisites: 003-D02; DD12/DD17 redirect contracts.
- Scope: Prove one operation retains its lifecycle across URLProtocol instances and automatic or delegate-directed redirect decisions.
- Expected files/modules: Isolated redirect server/protocol fixtures and findings.
- Public behavior: None; evidence for response-owned redirects and request derivation without stable routing/correlation headers.
- Tests/verification: V-spike; automatic follow, refusal, modification, relative targets, multiple hops, method/body rewriting, cross-origin credentials, loops/limits, unanswered decisions, cancellation, and post-decision timing.
- Exclusions: Flattening to the final response, changing live redirect policy, cross-client portability, production implementation.
- Checkpoint: R; report every platform gap; do not narrow required redirect semantics without owner-approved decision changes.

### 003-D04 — Basic and Digest challenge spike

- Recommended model: GPT-6 Astra; reasoning: `xhigh`. Native Basic/Digest challenge behavior, repeated continuations, and safe credentials require careful cross-bridge experiments.
- Prerequisites: 003-D02; DD12/DD17 authentication and credential contracts.
- Scope: Prove task-level 401/407 challenge presentation, native sender/decision bridging, and repeated continuations with safe credential metadata.
- Expected files/modules: Isolated deterministic challenge fixtures and findings.
- Public behavior: None; evidence for Basic/Digest and unsupported challenge boundaries on each intended bridge.
- Tests/verification: V-spike; use-credential/default/reject/cancel/open paths, repeated failures, proposed credential metadata, no persisted/logged passwords, response body/failure continuations, and ordinary HTTPS default handling.
- Exclusions: Platform-security challenge virtualization, storing native trust objects, hand-implementing HTTP authentication, production dependency adoption.
- Checkpoint: R; present reproducible failures and any DD12 amendment needed.

### 003-D05 — Native quiescence and consolidated feasibility gate

- Recommended model: GPT-6 Astra; reasoning: `xhigh`. Prove native quiescence and forwarding-tail ownership, then reconcile all spike results with the production boundary.
- Prerequisites: 003-D01–003-D04; DD10, DD12, DD14, DD17.
- Scope: Prove shutdown/cancellation/routing ownership and consolidate all six spike questions into a reviewed per-platform capability matrix.
- Expected files/modules: Isolated lifecycle tests; consolidated findings with links to executable cases and any proposed decision amendment.
- Public behavior: None; a reviewed boundary for production implementation.
- Tests/verification: V-spike; pending/in-flight callbacks, unanswered decisions, route removal, escaped sessions, no replay delivery after quiescence, minimal live forwarding tails completing without scenario retention/mutation, repeated setup/cleanup without leaks; macOS, Linux and iOS evidence.
- Exclusions: Canceling consumer-owned live work to pass teardown, timeout-based claims of quiescence, production promotion of the spike, hiding lost phases.
- Checkpoint: R; confirm or revise H/I decomposition against findings under resolved Q1.
  No affected production work proceeds while a required boundary is disproved.

## Phase E — Scheduler and reusable grouped behavior

### 003-E01 — Execution logical-time and capture service

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Public logical-time capture must preserve observation order, checked arithmetic, and isolation without exposing host instants.
- Prerequisites: 003-C07, 003-A01; DD03, DD06, DD14; Q2 resolved.
- Scope: Establish one execution origin at completed startup and a narrow public system service for logical Duration and monotonic capture tokens.
- Expected files/modules: `DioramaCore` time service, internal clock injection, availability and origin tests.
- Public behavior: All attachments share one ContinuousClock origin/rate; random remains untimed.
  Runtime instants never become stable snapshot values.
- Tests/verification: V-code; startup-origin boundary, monotonicity, checked arithmetic, independent executions, observation-before-conversion timing, concurrent/mixed-mode reads, iOS 16/macOS 13 API availability.
- Exclusions: Deadline queue, public host instants, time controls, persistence of absolute capture chronology, generic timestamp fields on every record.
- Checkpoint: R; review public time-service scope and isolation.

### 003-E02 — One-to-one deadline engine and deterministic handoff

- Recommended model: GPT-6 Astra; reasoning: `xhigh`. Earliest-wait replacement, due-batch claims, and non-reentrant deterministic handoff are tightly coupled scheduler rules.
- Prerequisites: 003-E01; DD14.
- Scope: Add one active earliest-deadline wait, earlier insertion replacement, due-batch claiming and delivery outside scheduler isolation.
- Expected files/modules: Core deadline engine and internally injected-clock ordering tests; minimal scheduling lease API.
- Public behavior: Zero requested tolerance and no deliberate early delivery; due work waits for the next drain.
  Order is deadline, attachment, stable track/record order, then atomic registration order, not resumed-task execution.
- Tests/verification: V-code; equal/overdue deadlines, complete batch claimed before handoff, earlier insertion, late wakes preserving order, zero delay non-reentrancy, overflow rejection; small real-clock platform smoke cases.
- Exclusions: Playback rates, public virtual/manual clocks, global task-idle detection, consumer callbacks under scheduler isolation.
- Checkpoint: R; review timer ownership and handoff-order evidence.

### 003-E03 — Cancellation, acknowledgements, and scheduler quiescence

- Recommended model: GPT-6 Astra; reasoning: `xhigh`. Atomic cancellation versus claim and in-flight acknowledgements must prove no delivery after finalization.
- Prerequisites: 003-E02, 003-B08; DD10, DD14.
- Scope: Complete scheduled-item pending/claimed/delivered/canceled state and execution shutdown, including in-flight delivery acknowledgement.
- Expected files/modules: Core scheduler handles/shutdown and race tests.
- Public behavior: Cancellation races atomically with claim and is idempotent; finish closes admission, cancels pending work, drains claimed callbacks, and returns only after quiescence.
  Late timer wakes cannot restart delivery.
- Tests/verification: V-code; cancel-before/after-claim, earliest-item cancellation, no double resume, callback reentry, attempted rescheduling during finish, canceled finish waiter, no scheduled delivery after final result on all platforms; new misuse diagnostics do not restart scheduling.
- Exclusions: Forcefully terminating consumer code, finalization timeout policy, consumer-task quiescence detection, returning selected groups to availability.
- Checkpoint: R; require ownership/race evidence before timed system delivery.

### 003-E04 — Strict grouped lifecycle accumulation

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Reusable typed accumulators must enforce one horizon conclusion and reject late or conflicting observations.
- Prerequisites: 003-E01, 003-B04, 003-B08; DD03, DD06, DD10.
- Scope: Introduce reusable typed interaction/subscription accumulators with correlated phases and a single explicit immutable horizon conclusion.
- Expected files/modules: Core behavior helpers and lifecycle validation tests.
- Public behavior: Runtime observations may arrive incrementally, but immutable groups have exactly one returned/failed/open or finished/failed/open conclusion.
  Nonterminal stream errors are distinct; caller cancellation is not a record.
- Tests/verification: V-code; overlapping groups, interleaved observations, reservation order, missing/duplicate terminals, open freeze, late event rejection, complete candidate validation and health on grouping failure.
- Exclusions: Universal event enum, HTTP tree shape, flat persisted event format, native object storage, scheduler delivery implementation.
- Checkpoint: R; review the shared invariant; split interaction and subscription helpers into smaller commits or review subunits if the actual diff warrants it.

### 003-E05 — System selectors and atomic grouped claims

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Pure system selectors, atomic whole-group claims, and distinct failure diagnostics extend the established claim boundary.
- Prerequisites: 003-E04, 003-B04, 003-B08; DD04–DD05.
- Scope: Extend atomic claim coordination to deterministic system-selected whole groups, with exact-input and sequential helpers where applicable.
- Expected files/modules: Core selection/claim helpers, usage report extensions, consumer selector conformance tests.
- Public behavior: Earliest available equivalent groups advance once; missing, exhausted, ambiguous, and invalid selector results differ.
  Cancellation or a failed continuation never rolls a claim back.
  Progress is separate from use.
- Tests/verification: V-code; reordered distinct calls, repeated equivalents, concurrent claims, unavailable/out-of-scope selection, open/incomplete claims, scenario/attachment evaluation including opt-in selected-completion checks.
- Exclusions: HTTP projection, universal match keys, implicit test assertions, reusable groups, cardinality ranges, claim persistence.
- Checkpoint: R; review selector purity, safe differences, and claim atomicity.

### 003-E06 — Sequential stream delivery over grouped claims

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Subscription anchors, open groups, and cancellation races compose already proved scheduler and lifecycle services.
- Prerequisites: 003-E03–003-E05; DD03–DD05, DD14.
- Scope: Provide reusable subscription selection and ordered scheduled delivery for values, nonterminal errors, completion/failure, and open groups.
- Expected files/modules: Core stream behavior helper and controlled consumer stream tests with scheduler instrumentation.
- Public behavior: Each subscription gets its own anchor and private claimed lifecycle; open groups remain active after their last emission.
  Cancellation removes future work while preserving used/incomplete facts.
- Tests/verification: V-code; fresh subscription anchors, event order, empty/open groups, nonterminal error recovery, normal/failed conclusion, cancellation and finalization racing delivery, no post-quiescence callback.
- Exclusions: Location policy, replay matching individual emissions, persisting caller cancellation, independent application-task ordering guarantees.
- Checkpoint: R; review stream lifecycle before first-party location uses it.

### 003-E07 — Conditional interaction delivery

- Recommended model: GPT-6 Astra; reasoning: `high`. Reachability, decision-relative anchors, overdue delivery, and open continuations interact across several state machines.
- Prerequisites: 003-E03–003-E05; DD03–DD04, DD14, DD17 timing refinement.
- Scope: Deliver phases only when their deadlines and system-defined lifecycle prerequisites permit, registering only reachable continuations.
- Expected files/modules: Core interaction scheduling helpers and synthetic decision-bearing consumer tests.
- Public behavior: Invocation anchors and current-decision anchors are available to systems.
  Overdue work queues to the next drain; an incompatible continuation diagnoses without consuming another group; unanswered phases remain open.
- Tests/verification: V-code; early/late decisions, overdue non-reentrancy, post-decision local delay, unreachable branches, cancellation, acknowledgement, open and failed continuations, immutable usage/progress reports.
- Exclusions: HTTP matching or delegate policy, multiple authored alternative paths, persisting application decision latency, new public time controls.
- Checkpoint: R; review the DD14 mechanism and DD17 mapping with explicit examples.

### 003-E08 — External scheduling and mixed-mode conformance

- Recommended model: GPT-5.6 Sol; reasoning: `high`. External actor-aware scheduling and mixed-mode conformance must distinguish handoff order from task execution order.
- Prerequisites: 003-E06–003-E07; DD02, DD06, DD10, DD14.
- Scope: Prove scheduling, cancellation, acknowledgement, and capability helpers work from an ordinary external consumer module and across platforms.
- Expected files/modules: Consumer conformance target and core integration tests; scheduling/ownership documentation.
- Public behavior: First-party and consumer systems use identical public leases, with adapter-selected delivery isolation and no exposed host-clock instant.
- Tests/verification: V-code; mixed live capture/replay, slow conversion versus capture time, multi-attachment equal deadlines, independent executions, actor-aware delivery, repeated teardown, real-clock bounds on macOS/iOS/Linux.
- Exclusions: New behavior engines, custom playback mapping, stronger total order of racing resumed tasks, duplicating native adapters for the test.
- Checkpoint: R; stop with the complete scheduler/behavior-services milestone.

## Phase F — Portable clock system

### 003-F01 — Shared millisecond duration and ISO 8601 codecs

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Strict scalar grammars, independent rounding, numeric offsets, and overflow need precise portable codec tests.
- Prerequisites: 003-C02; DD08, DD15; 003-A01 selected platform matrix.
- Scope: Implement strict locale-independent signed ms/seconds grammar, canonical scalar writing, numeric-offset origins, rounding and checked maths.
- Expected files/modules: Shared stable-scalar/codec files at the lowest useful non-HTTP boundary; golden/rejection fixtures and format documentation.
- Public behavior: Integral ms or seconds with at most three fractional digits decode; zero writes 0ms, exact seconds write s, others ms. Origins retain the selected numeric UTC offset; no regional timezone rule is persisted.
- Tests/verification: V-code; signs, invalid syntax/ranges, overflow, precision, independent absolute nearest-ms rounding, retained offsets, DST-derived input offsets, canonical output across locales/platforms; review rounding tie rule.
- Exclusions: General date parser, locale-specific output, silent coercion, submillisecond wall precision, clock-system runtime behavior.
- Checkpoint: R; review scalar semantics before clock/location/HTTP schema use.

### 003-F02 — Empty and nonempty wall recordings

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Empty/nonempty wall schemas and cumulative signed deltas require one validated interpretation and strict rejection fixtures.
- Prerequisites: 003-F01, 003-C01–003-C02; DD03, DD08, DD15.
- Scope: Add strict empty/nonempty wall data, origin and successive signed observations, cumulative validation and deliberate version-one persistence.
- Expected files/modules: `DioramaClock` stable model/schema, fixtures and builders.
- Public behavior: Empty has no origin; nonempty canonical position zero is zero.
  Negative wall deltas change values without introducing replay delays.
  Builders and decoding both produce validated semantic values.
- Tests/verification: V-code; empty versus missing track, repeated/backward wall values, malformed origin/delta combinations, cumulative overflow, current schema goldens and unknown fields/tags/versions.
- Exclusions: Wall source, scheduler sleeps, general recorded-value wrappers on every field, runtime policy for arbitrary invalid public constructors.
- Checkpoint: R; review wall schema independently from observation mechanics.

### 003-F03 — Wall-source recording and passthrough

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Serialized wall capture combines timezone selection, independent rounding, and safe live-value forwarding.
- Prerequisites: 003-F02, 003-B04; DD06, DD09, DD15.
- Scope: Vend the synchronous nonthrowing Date wall facet with an injected Sendable source, serialized capture, and startup-selected encoding timezone.
- Expected files/modules: Clock wall source/live attachment and tests.
- Public behavior: Live modes return native observations.
  Record independently rounds absolute values before deriving deltas; first observed instant resolves the numeric timezone offset.
  Passthrough does not touch recordings.
- Tests/verification: V-code; known wall jumps, rounding without accumulated interval error, timezone change/DST, concurrent source-to-track order, multiple independent sources, safe preparation failure and live return.
- Exclusions: Live fallback in replay, persisting timezone rules or read timing, automatic clock attachment, monotonic source reads as recorded wall values.
- Checkpoint: R; review source ownership and Date-versus-prepared value behavior.

### 003-F04 — Sequential wall replay and exhaustion

- Recommended model: GPT-5.6 Terra; reasoning: `high`. Sequential replay reuses established claims and codecs, with explicit last-value continuation and closed-handle tests.
- Prerequisites: 003-F03, 003-B08; DD05, DD15.
- Scope: Replay effective origin plus accumulated deltas and report unused reads.
- Expected files/modules: Clock replay/finalization paths and conformance tests.
- Public behavior: Replay never calls the source; exhausted reads diagnose then repeat the last returned Date, or Unix epoch if none.
  Closed handles use the same value continuation with a distinct lifecycle diagnostic in every mode.
- Tests/verification: V-code; empty/absent setup distinction, extra/unused reads, backward/repeated values, independent keyed cursors, counted source factory, concurrency, finish and escaped wall handles.
- Exclusions: Waiting for wall deltas, simulating progress between reads, inferring which racing caller should receive which observation.
- Checkpoint: R; review total nonthrowing behavior and diagnostics.

### 003-F05 — Clock override normalization and re-record merge

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Positional override survival and fresh-observation merge rules must preserve the baseline and public extension boundary.
- Prerequisites: 003-F04, 003-C05; DD03, DD07, DD09, DD15.
- Scope: Add deliberate origin/later-delta overrides and clock-specific merge through the public candidate preparation/finalization extension boundary.
- Expected files/modules: Clock override codec/merge, necessary public merge hook, baseline-to-candidate fixtures and transient report tests.
- Public behavior: Override wins over observation; position-zero override folds into an overridden origin and canonical zero.
  Fresh deltas derive from fresh observed values; preserve surviving positional overrides and drop vanished positions or all obsolete values for an empty new recording.
- Tests/verification: V-code; tolerant forms, canonical override-only output, fresh origin/timezone, insert/remove observations, empty replacement, immutable old baseline and healthy publication after allowed override removal.
- Exclusions: Heuristic positional rematching, overriding random values, applying clock deletion policy to every system, sticky setup configuration.
- Checkpoint: R; review merge results and any public merge service addition.

### 003-F06 — Logical Swift Clock facet and closed-handle behavior

- Recommended model: GPT-6 Astra; reasoning: `high`. Swift Clock conformance combines cancellation, transferred logical instants, frozen horizons, and scheduler lifetime.
- Prerequisites: 003-F04, 003-E08; DD14–DD15.
- Scope: Add Sendable/Hashable/Comparable logical instants and Clock conformance using public scheduler services, including sleep cancellation and closure.
- Expected files/modules: Clock monotonic facet/instant and lifecycle tests.
- Public behavior: Instants are Duration offsets without execution identity; receiving executions interpret transferred offsets locally.
  Sleeps are never recorded.
  Finish cancels pending sleeps and freezes now; new closed sleeps diagnose and throw execution-closed, while canceled pending sleeps throw CancellationError.
  Closed now diagnoses and returns the frozen horizon.
- Tests/verification: V-code; instant arithmetic/range preconditions, past deadlines, tolerance, cross-attachment/execution offsets, no persisted sleep counts, cancellation races, frozen instant and all escaped-handle cases.
- Exclusions: Public host instants, wall-derived monotonic time, virtual time, broad availability beyond Q2, comparing cross-execution UUIDs.
- Checkpoint: R; review standard Clock API semantics and scheduler ownership.

### 003-F07 — Clock platform and complete-system conformance

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Full clock acceptance combines portable codecs, persistence, mixed timed systems, and quiescence evidence.
- Prerequisites: 003-F05–003-F06; DD15.
- Scope: Complete persisted/mixed-mode/portable clock evidence and user examples.
- Expected files/modules: Clock conformance fixtures and public-only consumer tests, clock capability and override documentation.
- Public behavior: Optional wall/monotonic facets work together or independently; multiple walls remain independent while monotonic deadlines share an execution.
- Tests/verification: V-code; macOS/iOS/Linux Date/timezone/scalar goldens, monotonic-only empty fixtures, concurrent calls, file re-record/replay, live-source isolation, clock timeouts alongside synthetic stream/interactions, quiescence and truthful minimum-runtime versus current-simulator evidence.
- Exclusions: Regional timezone persistence, calendars, new playback policies, adding an optional algorithms package without demonstrated need and approval.
- Checkpoint: R; stop at a complete clock milestone with documented limitations.

## Phase G — Location domain and Apple bridge

### 003-G01 — Portable location, access, and failure values

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Portable location and bounded error values need deliberate range, omission, and unknown-value contracts.
- Prerequisites: 003-F01, 003-B02; DD06, DD09, DD16, Q4.
- Scope: Define stable location measurements, access state, source information, and bounded property-list-like failure values independent of Core Location.
- Expected files/modules: `DioramaLocation` domain values, validation tests and supported-field/error-value documentation.
- Public behavior: Preserve floor, independent orthometric/ellipsoidal heights, timestamp, accuracy, speed/course and optional source flags; invalid native sentinels map to absence.
  Access preserves unknown permission/accuracy cases without rejecting plausible cross-field combinations.
  Failures retain domain/code.
- Tests/verification: V-code; finite/range checks, absent versus false source flags, nonpositive vertical accuracy, negative speed/course, canonical course, unknown access values, recursive error bounds and safe omission warnings.
- Exclusions: CLLocation in portable types, actual coordinate mapping, native manager, arbitrary object/error graphs, localized error identity guarantees.
- Checkpoint: R; review stable field and omission contracts; use smaller commits for independent value families when helpful.

### 003-G02 — WGS84 mapping and numerical contract evidence

- Recommended model: GPT-6 Astra; reasoning: `xhigh`. An evidence-backed WGS84 mapping and inverse must bound numerical error and singularities before schema adoption.
- Prerequisites: 003-G01; DD16 coordinate/scalar sections, dependency policy, Q4.
- Scope: Evaluate the common-origin east/north mapping, inverse, WGS84 constants, valid regional envelope and singularities against independent reference data.
- Expected files/modules: `Spikes/LocationCoordinates/` and `docs/evidence/location-coordinate-codec.md`; proposed stable mapping contract.
- Public behavior: None yet; fix a reviewable codec interpretation before fixtures depend on numerical choices, without claiming global route-shape preservation.
- Tests/verification: V-spike; known coordinate pairs, zero/displaced origins, antimeridian/polar cases, forward/inverse error, relocation, platform numerical agreement.
  Disclose any explored package and exact adoption proposal if needed.
- Exclusions: Silent projection choice, guessed Earth constants, unapproved production geodesy dependency, guaranteeing globally identical geodesics.
- Checkpoint: R; resolve Q4 and any dependency/decision changes before 003-G03.

### 003-G03 — Location version-one codec and strict recording model

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Implement an approved geographic contract alongside independent measurement/delivery origins and exact scalar encoding.
- Prerequisites: 003-G02 approved mapping, 003-C02, 003-F01; DD03, DD08, DD16.
- Scope: Implement coordinate/time encoding and grouped update/access payloads, including optional cached location and independent vertical origins.
- Expected files/modules: Location codec and strict recordings; geographic, numeric, time, failure and schema fixtures.
- Public behavior: Unit-bearing JSON numbers use finite shortest-round-trip doubles, normalized negative zero and no default quantization.
  One attachment horizontal origin is separate from session measurement origins and successive delivery delays.
  Access-only/empty recordings have no coordinate origins.
- Tests/verification: V-code; cross-platform goldens, longitude/latitude/course normalization, independent altitude components, cached timestamp, signed measurement versus nonnegative delivery time, malformed/unknown schema, bounds.
- Exclusions: Default lossy rounding of measurements, native archive payloads, one shared up coordinate, positional event overrides, Linux live capture.
- Checkpoint: R; review the stable geographic and lifecycle schema before replay.

### 003-G04 — Portable sequential update replay

- Recommended model: GPT-5.6 Sol; reasoning: `high`. AsyncSequence updates, cached state, open sessions, and iterator cancellation require a coherent portable lifecycle.
- Prerequisites: 003-G03, 003-E06; DD04–DD05, DD16.
- Scope: Add AsyncSequence-first update events, ordered batches/nonterminal failures, one active update session, and non-consuming current location.
- Expected files/modules: Location portable service/update state machine and tests.
- Public behavior: Start inactive selects the next group; repeated active start and inactive stop are idempotent.
  Restart gets a fresh anchor.
  Current location updates before delivery and survives failure.
  Open groups stay active/silent; exhausted start diagnoses and becomes inert if the handler returns.
- Tests/verification: V-code; batch order, duplicate/cached measurement times, failure then recovery, current reads, start/stop/restart, iterator cancellation, inert-session release, selected/incomplete report, basic shutdown quiescence.
- Exclusions: Matching manager configuration, concurrent sessions within one attachment, failure as thrown termination, synthetic completion on mismatch.
- Checkpoint: R; review the full portable update lifecycle and offline guarantee.

### 003-G05 — Access state notifications and authorization barriers

- Recommended model: GPT-6 Astra; reasoning: `high`. Authorization barriers and state-before-callback ordering interact with mismatches, scheduling, and shutdown.
- Prerequisites: 003-G04, 003-E03; DD16 access/request contracts.
- Scope: Implement initial/current access state, separate state sequence, automatic notifications, and ordered when-in-use/always request barriers.
- Expected files/modules: Location access state machine and timed barrier tests.
- Public behavior: Initial state is readable before initial notification; observation begins at sequence/delegate registration.
  Complete state installs before callbacks; duplicates remain visible.
  Matching requests release barriers and re-anchor following delays; mismatches leave the marker untouched.
- Tests/verification: V-code; no-request external changes, duplicate notifications, callback reads, expected request never made/unused, early/wrong/duplicate requests, independent attachments, no live calls, cancellation and finalization races.
- Exclusions: Assuming requests caused state changes, comparing request timing, turning disabled services into failure, configuration or state-read consumption.
- Checkpoint: R; review barrier consumption and nonthrowing mismatch continuation.

### 003-G06 — Location origin policy and re-record replacement

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Origin precedence and surviving-session overrides must preserve fresh derivation while excluding raw sensitive values.
- Prerequisites: 003-G03–003-G05, 003-F05, 003-C05; DD09, DD16.
- Scope: Add preparation and merge for coordinate/measurement origins while replacing other location behavior wholesale on re-record.
- Expected files/modules: Location origin policy/merge, privacy and file fixtures.
- Public behavior: Authored origin override wins over re-evaluated setup default, then fresh origin.
  Derive fresh offsets/deltas before substitution.
  Defaults persist as observed, not sticky overrides.
  Keep session measurement overrides only where the corresponding sequential session survives.
- Tests/verification: V-code; relocation/retiming, independent vertical origins, disappearing sessions/locations, access-only replacement, changed defaults, transient raw origins absent from candidate/resources/diagnostics, override-only canonical writing, non-origin manual edits replaced as documented.
- Exclusions: Whole-event/track overrides, heuristic event correspondence, claims that relocation removes all sensitive route information.
- Checkpoint: R; review precedence, deletion behavior, and safe prepared output.

### 003-G07 — Main-actor delegate facade over portable replay

- Recommended model: GPT-5.6 Sol; reasoning: `high`. A narrow MainActor facade must preserve weak-delegate ownership and exact frozen/inert post-finish behavior.
- Prerequisites: 003-G04–003-G05; DD16 consumer and escaped-handle contracts.
- Scope: Add the narrow Diorama-owned Apple facade and weak delegate with portable locations, reproducible Apple access/configuration types and local replay state.
- Expected files/modules: `DioramaCoreLocation` facade/delegate target, controlled main-actor replay tests and migration example.
- Public behavior: Current access/location are non-consuming; callbacks run on MainActor.
  The facade exposes only standard updates, two authorization requests, desiredAccuracy/distanceFilter/activityType/pauses configuration.
  Configuration is neither persisted nor matched.
  Closed handles are frozen/inert per DD16.
- Tests/verification: V-code on Apple platforms plus Linux portable build; weak delegate, state-before-callback, Error reconstruction, replacing delegate after finish produces no callback, inert setters/start/requests and no-op stop.
- Exclusions: CLLocationManager subclassing, native location reconstruction tricks, background/deferred/significant-change/heading/region/one-shot APIs.
- Checkpoint: R; review the bounded adoption surface independently from live access.

### 003-G08 — Private Core Location capture and live forwarding

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Native callback conversion and live forwarding need field-fidelity evidence, safe preparation, and clear manager ownership.
- Prerequisites: 003-G06–003-G07, 003-B02, 003-E01; DD06, DD09, DD16.
- Scope: Add an owned private MainActor CLLocationManager bridge for record and passthrough, reserving ordering/time and copying values at native callbacks.
- Expected files/modules: Core Location native bridge/converters and controlled adapter-boundary tests; documented native field availability.
- Public behavior: Forward configuration and supported native behavior; record prepared portable values while live consumers receive the promised facade values/native Error.
  Unsupported user-info entries warn and omit only that value; other conversion failures preserve live behavior and block publication.
- Tests/verification: V-code; supported measurement fields and unknown access values, callbacks/errors, initial cached location, batching, no raw origin leak, source isolation, passthrough no track changes, counted owned-manager operations.
- Exclusions: Consumer-manager mutation, live Linux source, native error string persistence, nondeterministic simulator GPS as the sole correctness evidence.
- Checkpoint: R; review native conversion fidelity and owned-manager boundaries.

### 003-G09 — Location shutdown and cross-platform acceptance

- Recommended model: GPT-6 Astra; reasoning: `high`. Manager/proxy/sequence cleanup must prove quiescence across batches, barriers, late events, and platform boundaries.
- Prerequisites: 003-G08; DD10, DD14, DD16.
- Scope: Complete private-manager/proxy/sequence cleanup and broader portable, Apple, multi-attachment and re-record conformance.
- Expected files/modules: Location/Core Location integration tests, capability documentation, Apple controlled callback harness and portable replay fixtures.
- Public behavior: Finish stops the owned manager, detaches proxy, cancels pending and drains claimed callbacks, ends async sequences as runtime cleanup, and leaves escaped handles inert without inventing a delegate completion.
- Tests/verification: V-code; finish during batches/access barriers, cancellation, late native events, no location callbacks after finish, all frozen-property rules, multiple independent managers, Apple-recorded portable fixtures replaying on Linux; actual Apple integration evidence distinguished from controlled mocks.
- Exclusions: Treating simulator lack of deterministic GPS as evidence of live fidelity, adding unsupported services, persisting teardown as stream completion.
- Checkpoint: R; stop at the complete initial location milestone.

## Phase H — Shared HTTP and stable URLSession lifecycle

This phase implements shared semantics and adapter-owned stable supplements.
Under resolved Q1, its provisional units can be reviewed now; 003-D05 must confirm or revise the affected breakdown against spike evidence before production implementation proceeds.
Add only the shared boundaries actually needed by URLSession; do not build an AsyncHTTPClient adapter to justify them.

### 003-H01 — Swift HTTP Types adoption record

- Recommended model: GPT-5.6 Terra; reasoning: `high`. Review two package products, exact compatibility, and the dependency graph against an existing adoption policy.
- Prerequisites: 003-A01, 003-C07, 003-D05 reviewed under resolved Q1; DD11, dependency policy.
- Scope: Evaluate a compatible stable release and propose explicit adoption of HTTPTypes for DioramaHTTP and HTTPTypesFoundation for DioramaURLSession.
- Expected files/modules: `docs/dependency-policy.md` adoption record and narrow isolated compatibility evidence if needed; no production dependency yet.
- Public behavior: No runtime change; exact version rule and owning products become reviewable before manifest edits.
- Tests/verification: V-doc/V-spike; canonical repository/package/products, major range and exact initial release, purpose, alternatives, transitive graph, license/maintenance, selected Swift toolchain and iOS16/macOS13/Linux support.
- Exclusions: Arbitrary latest revision, Algorithms/AsyncAlgorithms/NIO adoption, HTTP dependency in core, approval of unrelated products or future majors.
- Checkpoint: R plus explicit adoption approval; stop before 003-H02 changes manifests.

### 003-H02 — Shared message heads, fields, and body values

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Own the HTTP schema while preserving repeated fields and absent/empty/unavailable body distinctions.
- Prerequisites: 003-H01 adoption approval, 003-C02; DD08, DD11, DD17.
- Scope: Add HTTPTypes in-memory heads, ordered repeated fields, stable body cases and deliberate Diorama-owned message codecs/builders.
- Expected files/modules: `DioramaHTTP` message/body/field types, codecs and goldens; approved Package.swift additions and public documentation.
- Public behavior: Method/target/status/fields retain declared semantics; absent, empty bytes, resource bytes and response-only unavailable content differ.
  Resource references are stable values, never filesystem handles.
  No invented HTTP version or dependency-owned Codable output becomes Diorama's contract.
- Tests/verification: V-code; repeated fields including Set-Cookie, absent/empty request distinction, unsupported values, native-independent builders, exact byte fixtures, deterministic owned encoding and strict unknown-field rejection.
- Exclusions: Native Foundation wrappers in stable data, header dictionaries, universal failure enum, live URLSession, premature general resource spooling.
- Checkpoint: R; review value semantics and schema independently from lifecycle.

### 003-H03 — Typed HTTP preparation and credential defaults

- Recommended model: GPT-6 Astra; reasoning: `high`. Credential defaults and consumer transforms must preserve valid replay substitutes and exclude secrets at every boundary.
- Prerequisites: 003-H02, 003-B02; DD09, DD11, DD17.
- Scope: Implement immutable setup preparation for inputs/outputs/errors, with structural canonicalization, credential redaction, normalization and validation.
- Expected files/modules: HTTP typed policy/transform and safe-diff helpers; credential, malformed-field and consumer-transform tests.
- Public behavior: Default safe substitutes cover Authorization, Proxy-Authorization, Cookie, Set-Cookie, Authentication-Info and Proxy-Authentication-Info.
  Preserve useful scheme/cookie syntax where possible; unparseable recognized fields get a safe whole-field substitute and warning, becoming unhealthy only if no valid safe substitute can be formed.
- Tests/verification: V-code; same preparation on capture/decoded/edit/replay inputs, deterministic idempotence, secret-marker exclusion at every admission boundary, original live value unchanged, user rules and failed preparation.
- Exclusions: Default body mutation, automatic custom API-key discovery, transforming WWW-Authenticate/Proxy-Authenticate by default, raw logging, pseudonyms/named values, JSON-path parser/sanitizer feature design.
- Checkpoint: R; review precise defaults and validity of replay substitutes.

### 003-H04 — Standard HTTP matcher and safe differences

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Prepared projections and safe differences need precise header-order, exact-body, and resource-equivalence semantics.
- Prerequisites: 003-H03, 003-E05; DD04, DD09, DD11.
- Scope: Match prepared method, scheme/authority, path/query, exact logical body, and prepared fields with the accepted configurable exclusion defaults.
- Expected files/modules: HTTP matcher/projection/diff files and matching tests.
- Public behavior: Default exclusions are Host, Content-Length, Connection, Keep-Alive, Proxy-Connection, Transfer-Encoding, and User-Agent; routing fields never enter prepared values at all.
  Name comparison is case-insensitive; order between different names is ignored and repeated-value order retained.
  Include/exclude/strict-inclusion/typed matcher setup options are explicit.
- Tests/verification: V-code; reordered and repeated requests, meaningful custom fields and conditional headers, body absent/empty, inline/resource equivalence via controlled resolver, opt-in User-Agent, ambiguity/exhaustion safe diffs.
- Exclusions: Silent query reordering, semantic JSON matching, multipart boundary normalization, ignoring a field as a substitute for redacting it.
- Checkpoint: R; review full default field projection and selection diagnostics.

### 003-H05 — Strict response/body/failed/open lifecycle

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Recursive attempt/body results and tolerant persistence must validate to one strict lifecycle without duplicate content.
- Prerequisites: 003-H02, 003-E04, 003-F01; DD03, DD11, DD17.
- Scope: Add one root request and mutually exclusive attempt/body results, with response-owned head/content, partial prefixes and completion-only trailers.
- Expected files/modules: HTTP recursive lifecycle foundation, validation/builders and owned codecs; synthetic typed failure supplement for focused tests.
- Public behavior: No extra top-level conclusion can contradict a leaf.
  Pre-head failure differs from failure after a prefix.
  Open before/after a head remains explicit; HTTP 4xx/5xx can return successfully.
  Body content appears once.
- Tests/verification: V-code; malformed/missing/conflicting leaves rejected, unavailable versus empty/absent, partial failed/open bodies, trailer placement, tagged schema goldens and public builder validation.
- Exclusions: Redirect/authentication/disposition nodes until 003-H10–003-H12, synthetic completion for open work, informational 1xx/wire-level behavior.
- Checkpoint: R; review runtime validity separately from native delivery.

### 003-H06 — Weighted body allocation and local timing

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Proportional byte allocation, zero weights, integer rounding, and cumulative delays need checked arithmetic and independent examples.
- Prerequisites: 003-H05; DD14, DD17, 003-F01.
- Scope: Implement successive nonnegative delays and byte-weight profiles with checked cumulative arithmetic and deterministic proportional allocation.
- Expected files/modules: HTTP body profile/timing validation and fixture tests.
- Public behavior: Unchanged bytes reproduce observed boundaries; edited length scales contiguous allocations, final segment absorbing remainder.
  All-zero weights put a later nonempty body into the final segment; absent/unavailable bodies cannot have profiles.
  Delays retain explicit override semantics.
- Tests/verification: V-code; rounding-boundary examples and review of selected integer rule, zero/empty content, larger/smaller edits, non-UTF8 boundaries, exact total coverage/no range overflow, successive delay overflow/negatives, one effective runtime interpretation for tolerated editing forms.
- Exclusions: Duplicate segment bytes, requiring text-safe split points, persisting runtime task/queue identity or application decision latency.
- Checkpoint: R; review allocation/scalar choices before native body replay.

### 003-H07 — Atomic resources with the first resource-backed consumer

- Recommended model: GPT-6 Astra; reasoning: `xhigh`. Atomic document/resource generations must survive concurrent readers, replacement failures, and cleanup on every platform.
- Prerequisites: 003-H02–003-H03, 003-H05–003-H06, 003-C03–003-C06; DD07–DD09, DD17.
- Scope: Extend repository publication to one logical document/resource set, using the first real HTTP body references; fix portable resource naming/layout.
- Expected files/modules: Persistence resource resolver/staging/publication, HTTP resource integration, fixtures and failure-injection evidence.
- Public behavior: Prepared bytes publish with their referencing document; readers see one complete generation.
  References are normally scenario-relative; inline/resource storage has identical byte meaning.
  Replay needs no writes.
- Tests/verification: V-code; missing/unreadable/invalid references, safe path validation, old-reader resources during replacement, failed staging/commit, cleanup without breaking published readers, concurrent last-writer publication, prepared-only bytes and read-only replay on all applicable platforms.
- Exclusions: Raw adapter spool generalized into repository staging, digests required solely to forbid edits, optimistic locks, multi-file partial success.
- Checkpoint: R; review exact layout and logical atomicity before resource output.

### 003-H08 — Exact JSON resources and derived Content-Length

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Exact JSON bytes and provable Content-Length derivation require careful HTTP exception handling without mutation.
- Prerequisites: 003-H07, 003-H06; DD11, DD17.
- Scope: Select exact .json resources for valid UTF-8 application/json or +json bodies and implement the explicit body-byte-count field form when provable.
- Expected files/modules: HTTP body persistence selection/derived fields, fixtures preserving JSON byte spelling and body-edit integration tests.
- Public behavior: Keep whitespace, duplicate names, number spellings and escapes byte-exact.
  Derive only one valid Content-Length equal to a complete body with unambiguous method/status/encoding/transfer semantics; resolve from edited bytes before native materialization.
  Absent lengths remain absent.
- Tests/verification: V-code; JSON/+json detection, invalid UTF-8/JSON retained as exact opaque bytes, no re-encoding, edited resource/profile/length consistency, literal HEAD/partial/compressed/mismatched/repeated lengths, authored literal mismatch, ETag/Digest/Content-MD5/signatures unchanged, safe preparation first.
- Exclusions: JSON pretty printing/canonical matching, competing structured body, recomputing validators or inventing signatures, overriding literal fields.
- Checkpoint: R; review exact-byte authoring contract and derivation proof cases.

### 003-H09 — Stable URLSession failure supplements

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Bounded native error extraction and reconstruction must preserve useful identity while omitting unsafe object graphs.
- Prerequisites: 003-H05, 003-B02, 003-D02/003-D05 evidence; DD12, DD17, Q4.
- Scope: Define URLSession-owned failure values, bounded safe userInfo allowlist, native extraction/materialization helpers and deliberate codec.
- Expected files/modules: URLSession stable failure/conversion files and tests; no interception implementation yet.
- Public behavior: Preserve NSError domain/code, unknown numeric URLError codes, optional recognized name/prepared failing URL and approved typed metadata.
  Unsupported entries warn with key/type only and omit without poisoning health.
  Replay reconstructs fresh NSError/URLError; infrastructure errors stay distinct.
- Tests/verification: V-code; supported/unknown codes, bounded nested values, unrendered secret/object/underlying-error omission, replay reconstruction, native error forwarding unchanged, strict persisted fields and tags.
- Exclusions: Universal HTTP failure taxonomy, localized descriptions/security objects/custom subclass identity, treating HTTP status as transport failure.
- Checkpoint: R; review exact allowlist and limits before adapters capture errors.

### 003-H10 — Response-owned redirect branches

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Typed redirect branches and inherited requests must retain single ownership through recursive schema validation.
- Prerequisites: 003-H05–003-H06, 003-H09, 003-D03 reviewed; DD17.
- Scope: Add typed proposed/followed/modified/refused/open redirect structure, request derivation and its codec/validation.
- Expected files/modules: HTTP redirect composition and URLSession supplements; recursive structural fixtures/builders.
- Public behavior: Store the redirect response/proposed request once; unchanged follow derives the effective request, modified follow stores it only once, refusal owns that response's delivered body, followed body is unavailable.
- Tests/verification: V-code; multi-hop structure, mutually exclusive branches, current-decision continuation timing, invalid nesting, changed branch mismatch, no duplicate message storage and canonical JSON.
- Exclusions: Native redirect callback wiring, multiple alternative recorded continuations under one decision, comparing application decision latency.
- Checkpoint: R; review structural ownership against 003-D03 native evidence.

### 003-H11 — Response-owned authentication branches

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Authentication continuations combine safe credential shape, response ownership, and strict recursive branch validation.
- Prerequisites: 003-H10, 003-D04 reviewed; DD09, DD12, DD17.
- Scope: Add typed Basic/Digest challenge metadata and recursive continuations attached to the owning 401/407 head, with prepared credential shape.
- Expected files/modules: Shared authentication node composition, URLSession challenge supplements/codecs, redaction and tree fixtures.
- Public behavior: Preserve host/port/protocol/realm/proxy, previous failures, safe proposed-credential metadata, disposition, prepared username/persistence but no password.
  Retry inherits the request unless an observed material change requires an explicit edge value; cancel records the resulting failure once.
- Tests/verification: V-code; use/default/reject/cancel/open, repeated challenges, response-body/failure/retry continuation shapes, no duplicate failure response, secret exclusion, invalid method/head/branch rejection and canonical encoding.
- Exclusions: Trust/certificate or response-less challenges, authentication algorithm implementation, raw credentials as shared retry fields.
- Checkpoint: R; review stable challenge semantics before native replay.

### 003-H12 — Optional response-disposition supplement

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Optional disposition nodes have bounded scope but must preserve one conclusion and decision-relative timing.
- Prerequisites: 003-H05, 003-H09, 003-D02 reviewed; DD12, DD17.
- Scope: Add response-head allow/cancel/open decision supplements and validation.
- Expected files/modules: URLSession stable disposition composition/codec tests.
- Public behavior: Supplement exists only if a native decision was observed; allow leads to body delivery, cancel to one failure, unanswered to open.
  Body delay begins when the current allow decision returns.
- Tests/verification: V-code; absent supplement presentation independence, required compatible delegate capability when present, unknown/unsupported transitions, no synthetic allow for completion/async recordings, safe mismatch.
- Exclusions: becomeDownload/becomeStream transitions, mandatory decision nodes for every response, native callback implementation.
- Checkpoint: R; review presence/absence meaning and single-conclusion ownership.

### 003-H13 — Full lifecycle validation, registration, and capability derivation

- Recommended model: GPT-6 Astra; reasoning: `high`. Whole-tree validation and capability derivation integrate all schema families before any playback or claim is allowed.
- Prerequisites: 003-H08–003-H12, 003-E05/003-E07, 003-C01; DD08, DD11–DD12, DD17.
- Scope: Integrate one URLSession persistent system payload using shared HTTP codecs and typed supplements; derive required capabilities from the whole tree.
- Expected files/modules: HTTP/URLSession validators, registration/builders, capability checker and complete schema fixtures/documentation.
- Public behavior: Builders and decoders share strict validation.
  Unknown node, unavailable resource or unsupported bridge capability fails before any claim or playback.
  One system identity/schema works across both native bridges; no companion track or persisted platform/capability list duplicates the tree.
- Tests/verification: V-code; deep paths with attachment/interaction/attempt/field diagnostics, all node families, tolerated overrides/body edits, complete capability rejection, heterogeneous version dispatch and safe resource errors.
- Exclusions: Cross-client replay promise, platform-specific schema forks, dropping unsupported nodes, arbitrary adapter metadata bags.
- Checkpoint: R; review the complete runtime and persistence invariant together.

### 003-H14 — HTTP timing-override correspondence and re-recording

- Recommended model: GPT-6 Astra; reasoning: `xhigh`. Re-record correspondence must preserve overrides only along compatible structures and refuse ambiguous reassignment.
- Prerequisites: 003-H13, 003-H04, 003-F05, 003-C05; DD03–DD04, DD09, DD17.
- Scope: Match fresh prepared interactions to baseline groups and preserve delay overrides only at compatible structural paths and decision branches.
- Expected files/modules: HTTP merge service and baseline/candidate fixtures; safe transient override report coverage.
- Public behavior: Equivalent repeated requests pair by prior stable sequence; every persisted HTTP delay may override.
  Removed nodes/branches lose obsolete overrides informationally; heads/bodies/failures/branch choices are replaced.
  Unresolved correspondence preserves the prior fixture and reports resolution is needed instead of silently reassigning authored behavior.
- Tests/verification: V-code; reordered/repeated inputs, changed match policy, compatible/missing redirect/auth/disposition/body paths, fresh observations discarded beneath surviving overrides, resource edits, unhealthy merge refusal.
- Exclusions: Sticky message/subtree overrides, generic positional merge imposed on HTTP, moving overrides based on execution-generated correlation IDs.
- Checkpoint: R; review exact re-record diffs before native recording uses them.

## Phase I — Production URLSession bridge increments

Each unit extends one public URLSession system.
Bring the relevant spike cases into production conformance tests deliberately; do not import the spike package.
Every intermediate profile rejects both permanently excluded and not-yet-built operations, including in passthrough.
A unit passes only for capabilities proved on its declared platforms.
Temporary differences are documented; the complete milestone is not delivered while required surfaces remain unimplemented or unresolved.
Narrowing the milestone requires an approved decision amendment.

### 003-I01 — Instrumented session and bodyless GET vertical path

- Recommended model: GPT-6 Astra; reasoning: `xhigh`. The first native vertical path combines routing, live forwarding, replay isolation, rejection, and basic shutdown.
- Prerequisites: 003-D05 evidence review, 003-H13–003-H14, 003-E08; DD10, DD12, DD17, resolved Q1.
- Scope: Implement configuration-first adapter-owned sessions and private forwarding machinery, routing leases, rejection boundary, and minimal supported GET record/replay/passthrough from stable scenario to native result.
- Expected files/modules: `DioramaURLSession` setup/routing/protocol and Apple/ FoundationNetworking bridge files, GET fixtures and capability documentation.
- Public behavior: Copy default/ephemeral configurations, reject background and detectable unsupported delegates, disable cache, preserve supported settings and custom protocol order.
  Strip/reject reserved routing collisions, prevent forwarding reentry, validate active route, and never fall back during replay.
- Tests/verification: V-code; bodyless GET first on macOS/Linux then iOS, all modes, configuration immutability, two sessions/executions, routing stripped before preparation/diagnostics/network, unknown/expired routes, zero live replay access, startup rollback, basic cancellation/finish/escaped-session failure.
- Exclusions: Global protocol registration, shared/existing-session mutation, advertising bodies/delegate decisions/redirects/auth before their units, live bypass for unsupported tasks or non-HTTP schemes.
- Checkpoint: R; review the smallest safe native vertical path and its precise temporary profile.
  Any failed rejection guarantee stops adapter rollout.

### 003-I02 — In-memory bodies and aggregate data-task presentations

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Extend the proved adapter to body and aggregate presentations while retaining exact bytes and source isolation.
- Prerequisites: 003-I01, 003-H08; DD11–DD12, DD17.
- Scope: Extend supported requests to absent/in-memory bodies and complete responses through URL/URLRequest completion and async conveniences.
- Expected files/modules: URLSession extraction/materialization/data-task paths; aggregate and HTTPTypesFoundation convenience conformance tests.
- Public behavior: Exact logical request bytes participate in matching; response content is stored once, inline or resource-backed.
  Foundation supplies aggregate results from one replay lifecycle.
  Original live requests are not sanitized in place.
  Task-delegate overloads are supported only where evidence proves them.
- Tests/verification: V-code; all supported constructors/overloads, empty versus absent bodies, JSON and binary resources, default HTTPS forwarding, cookie/ credential settings, derived/literal length cases, total timing, record and passthrough forwarding, replay cancellation and no live access.
- Exclusions: Upload/download/body streams, form/multipart/JSON semantic matching, fabricating lost native distinctions or response fields, wire-byte guarantees.
- Checkpoint: R; review exact bytes and presentation coverage per bridge.

### 003-I03 — Native failure record/replay

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Integrate native failure timing and partial bodies without conflating dependency errors, caller cancellation, and infrastructure facts.
- Prerequisites: 003-I02, 003-H09; DD06, DD12, DD17.
- Scope: Connect native error observation/reconstruction to attempt and partial body failures with timing and safe warning/health rules.
- Expected files/modules: URLSession failure paths and controlled error fixtures.
- Public behavior: Return native live errors in record/passthrough; replay the stable domain/code/approved metadata as a fresh native error.
  Dependency cancellation before caller cancellation differs from caller runtime control.
- Tests/verification: V-code; timeout and connection errors, unknown codes, before-head/after-prefix failure, unsupported userInfo omission without health failure, failed preparation preserving live errors but refusing publication, HTTP 4xx/5xx normal success, all available native failure channels.
- Exclusions: Stringified errors, universal HTTP taxonomy, treating a Diorama mismatch as recorded dependency behavior, unbounded underlying-error graphs.
- Checkpoint: R; review same-adapter error fidelity and platform differences.

### 003-I04 — Segmented delegate delivery and response disposition

- Recommended model: GPT-6 Astra; reasoning: `high`. Delegate disposition and segmented delivery introduce native handoff races and cancellation across presentation styles.
- Prerequisites: 003-I03, 003-H06/003-H12, 003-D02 evidence; DD12, DD17.
- Scope: Connect observed response/body segment timing and native data-delegate allow/cancel/open decisions to the shared lifecycle and scheduler.
- Expected files/modules: URLSession delegate proxy/delivery paths and conformance tests across delegate, completion and async presentation.
- Public behavior: Replay allocated segments through URLProtocolClient; Foundation chooses presentation.
  Record a disposition only when observed; allow anchors body timing, cancel emits its resulting failure once, open waits.
- Tests/verification: V-code; segment shape/edited lengths, empty deliveries, response-before-body, allow/cancel/unanswered/mismatch, no synthetic decision in completion/async records, task conversion rejection, cancellation/finish during handoff, declared delivery contexts and zero late replay callbacks.
- Exclusions: Callback queue/task identity promises, progress/KVO/metrics, download/stream conversion, advertising native trailers without evidence.
- Checkpoint: R; review observable delegate symmetry for each bridge.

### 003-I05 — Native redirects and recursive request derivation

- Recommended model: GPT-6 Astra; reasoning: `xhigh`. Production redirects combine recursive decisions, successive protocol instances, route continuity, and offline guarantees.
- Prerequisites: 003-I04, 003-H10, 003-D03 evidence; DD12, DD17.
- Scope: Wire redirect observation, client decisions, continuation selection and same-group correlation across successive URLProtocol instances.
- Expected files/modules: URLSession redirect bridge/proxy and conformance suite.
- Public behavior: Automatic or delegate follow/modification/refusal selects the recorded compatible branch.
  Preserve the response/request ownership from 003-H10; unanswered decisions remain open and mismatches fail without network access.
- Tests/verification: V-code; all 003-D03 cases including multi-hop, relative target, method/body rewrite, cross-origin credential preparation, loops/limits, refusal body, open branches, modified-request matching, current-decision timing, canceled/finished redirect and routing continuity without stable route data.
- Exclusions: Flattened final-response snapshots, overriding native policy, alternate authored continuation paths, redirect data in a companion track.
- Checkpoint: R; stop with per-platform conformance; revisit DD12 if required native behavior differs from the reviewed spike.

### 003-I06 — Native HTTP Basic authentication

- Recommended model: GPT-6 Astra; reasoning: `high`. Native challenge senders, safe credential decisions, repeated attempts, and shutdown must agree with the recorded tree.
- Prerequisites: 003-I05, 003-H11, 003-D04 evidence; DD12, DD17.
- Scope: Bridge task-level Basic challenges, prepared credential decisions and recursive continuations through native challenge APIs.
- Expected files/modules: URLSession challenge sender/proxy and Basic fixtures.
- Public behavior: Use/default/reject/cancel/open choose the compatible recorded continuation; raw passwords never enter stable state.
  Shared 401/407 response heads and inherited requests are not duplicated.
- Tests/verification: V-code; direct/proxy challenge where advertised, safe proposed credentials, previous failure counts, repeated challenges, username/ persistence comparison, replay mismatch, body/failure outcomes, cancellation versus challenge cancel, unanswered finalization, no replay live source.
- Exclusions: Digest until 003-I07, Security objects, response-less challenges, storing a real password to make native replay work, implementing Basic itself.
- Checkpoint: R; review Basic end-to-end fidelity and secret-marker tests.

### 003-I07 — Native HTTP Digest authentication

- Recommended model: GPT-6 Astra; reasoning: `high`. Digest extends the Basic path but needs strong scrutiny of volatile fields, retry behavior, and Linux capability evidence.
- Prerequisites: 003-I06, 003-D04 Digest evidence; DD12, DD17.
- Scope: Extend the native challenge path to Digest while preserving the same shared lifecycle, safe metadata and continuation contracts.
- Expected files/modules: URLSession Digest capability and conformance fixtures; minimal shared challenge-path corrections justified by actual behavior.
- Public behavior: Replay task-level Digest challenge dispositions and repeated attempts without reconstructing live authentication secrets or contacting a server.
- Tests/verification: V-code; Digest challenge forms proved by the bridge, retry/default/reject/cancel/open behavior, volatile challenge field policy, current-decision delays, failure counts, native record/passthrough equivalence, stable repeated-challenge persistence and offline replay on advertised platforms.
- Exclusions: Other password methods, hand-rolled Digest protocol, automatic sanitization of all challenge fields, parity claims unsupported by libcurl evidence.
- Checkpoint: R; review the complete initial Basic/Digest capability boundary.

### 003-I08 — Full open-horizon and native ownership conformance

- Recommended model: GPT-6 Astra; reasoning: `xhigh`. Prove production shutdown at every native phase while live forwarding tails continue without retaining or mutating the scenario.
- Prerequisites: 003-I07; DD03, DD05, DD10, DD12, DD14, DD17.
- Scope: Broaden the lifecycle protection present since 003-I01 across every native phase and open state, with failure/cancellation/re-record integration.
- Expected files/modules: URLSession ownership/race conformance tests and documented forwarding-tail topology; focused fixes only as evidence requires.
- Public behavior: Horizon stops recording immediately and permits necessary live forwarding tails without scenario retention; replay callbacks quiesce.
  Open before-head, partial-body and unanswered decisions never get invented terminal events.
  Escaped sessions fail deterministically and remain offline.
- Tests/verification: V-code; finish at every phase, repeated/concurrent/canceled finish waiters, no replay callbacks after quiescence, late live results forwarded without candidate mutation, source/session ownership, routing/lease release, used/incomplete facts and healthy explicit-open persistence.
- Exclusions: Canceling live work merely to reach a horizon, leak masking through global strong registries, recording caller cancellation, new timeout policy.
- Checkpoint: R; review production shutdown evidence independently from happy paths.

### 003-I09 — Complete URLSession capability and cross-bridge matrix

- Recommended model: GPT-6 Astra; reasoning: `high`. Reconcile the complete cross-bridge capability matrix and fixture portability without hiding unsupported required surfaces.
- Prerequisites: 003-I08, 003-H13–003-H14; DD11–DD12, DD17.
- Scope: Close the supported API/profile matrix, validate structural capabilities at setup, and exercise fixtures recorded on each bridge through the other.
- Expected files/modules: URLSession shared conformance fixtures, platform CI selection and evidence, supported-capability and rejection documentation.
- Public behavior: One system and persisted schema; Apple/Linux portability covers the tested intersection.
  Unsupported or unimplemented nodes/tasks fail at the earliest reliable point in every mode with no built-in HTTP fallback.
- Tests/verification: V-code complete matrix: all data-task presentations, bodies/segments, failures, redirects, Basic/Digest, disposition, open horizons, timing overrides/re-records, resource edits, mode isolation and cleanup.
  Exercise excluded configurations/tasks/decision delegates and record exact Linux Swift/libcurl support; distinguish observation-only exclusions such as unavailable metrics from detectable decision-bearing setup failures.
- Exclusions: Claiming the milestone complete on GET-only Linux, silently narrowing failed requirements, cross-client replay, unvalidated Apple platforms, watchOS URLProtocol support or optional native trailers without conformance.
- Checkpoint: R; stop for complete adapter acceptance or an explicit decision revision identifying remaining platform limits.
  A disabled test is not proof.

## Phase J — Test integrations and complete initial acceptance

### 003-J01 — Opt-in XCTest integration

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Opt-in XCTest reporting must honor context lifetime, concurrent diagnostics, and explicit core finalization.
- Prerequisites: 003-B08–003-B09, 003-C06; DD05, DD10, resolved Q3, quality policy.
- Scope: Provide a separate, explicit XCTest diagnostic/evaluation convenience using supported lifecycle APIs and captured setup source locations.
- Expected files/modules: `DioramaXCTest`, integration tests and usage example; target availability separated from core.
- Public behavior: Consumers select categories and install reporting themselves; core never calls XCTest.
  Lifecycle completion still awaits explicit/scoped finish; reporting a test issue does not replace a nonthrowing continuation or imply a thrown body for publication policy.
  Reporting honors the captured test context's lifetime; retained diagnostics cannot retroactively change a test.
- Tests/verification: V-code with controlled expected-issue capture; concurrent diagnostics, source location, setup/runtime/publication issues, final report evaluation, context expiry with later diagnostics still retained, no implicit installation, platform availability and no core imports.
- Exclusions: Trap as recommended default, undocumented framework teardown hooks, automatic failure policies, adding a third-party testing dependency.
- Checkpoint: R; review small opt-in policy/API and framework-boundary evidence.

### 003-J02 — Opt-in Swift Testing integration

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Swift Testing task context and issue delivery need framework-specific feasibility evidence and retained-reporter lifetime tests.
- Prerequisites: 003-J01's reviewed common integration policy, 003-B09, 003-C06; DD05, DD10.
- Scope: Add a separate Swift Testing diagnostic/evaluation convenience using the selected toolchain's supported test context and lifecycle facilities.
- Expected files/modules: `DioramaTesting`, integration tests and example; framework-independent shared helpers only where actual duplication warrants it.
- Public behavior: Opt-in selected facts become test issues with useful source attribution; structured execution outcomes and deterministic system continuation remain authoritative.
  Test context is not inferred from arbitrary global state or kept valid by a retained reporter after the test ends.
- Tests/verification: V-code; supported task/test context, concurrent issue delivery, source attribution, publication/cleanup failures, explicit policy, context expiry with later diagnostics still retained, no implicit installation, availability across the selected toolchain matrix.
- Exclusions: Adding swift-testing as a production package without a demonstrated need/adoption record, conflating reported issues with thrown scope errors, changing core runtime semantics for a framework convenience.
- Checkpoint: R; review API feasibility and any framework-specific limitation.

### 003-J03 — Combined-system acceptance suite

- Recommended model: GPT-6 Astra; reasoning: `xhigh`. Combined-system acceptance exercises timing, health, persistence, and shutdown invariants across the full public surface.
- Prerequisites: 003-C07, 003-E08, 003-F07, 003-G09, 003-I09, 003-J01–003-J02.
- Scope: Prove accepted cross-system invariants in small real consumer examples, without adding new features or a general stress/benchmark framework.
- Expected files/modules: Public-only acceptance test target/fixtures and complete CI capability/coverage evidence.
- Public behavior: Heterogeneous and repeated attachments coexist; configuration is setup-only; immutable definitions start independent runs.
  Record/replay/ passthrough and publication health retain their separate meanings.
- Tests/verification: V-code; clock replay with live HTTP capture, timed location with HTTP timeout, independent random domains, full file re-record/replay, partial mixed-mode preservation, ignored/unattached registered payloads, redaction failures blocking whole publication, concurrent finish and no late replay callbacks, cross-bridge resources/schema goldens, all platform coverage uploads.
- Exclusions: Global event interleaving assertions, network/GPS nondeterminism in required tests, silently repairing a design conflict in acceptance work.
- Checkpoint: R; report the completion matrix and residual limitations.
  If a failure needs a new capability or architecture, stop and name the owning unit.

### 003-J04 — User documentation and initial delivery review

- Recommended model: GPT-5.6 Sol; reasoning: `high`. Audit documentation and compiled examples against all delivered contracts, capabilities, and unresolved limitations.
- Prerequisites: 003-J03 and every required unit's acceptance evidence.
- Scope: Complete public setup, authoring, extension, lifecycle, schema, supported-platform, dependency and internal development documentation; review delivery.
- Expected files/modules: `README.md`, `docs/README.md`, `docs/design-overview.md`, public API docs/examples, schema/capability references, plan/index status.
- Public behavior: Documentation explains observed/override forms and per-system re-record loss rules; exact bodies versus preparation; report evaluation; no live replay fallback; open work, finalization and escaped handles; separate post-finish diagnostic inspection and test-context limits; minimum OS versus tested runtimes and per-bridge capability limits.
- Tests/verification: V-doc and final accepted V-code evidence from 003-J03; compile public examples, audit dependency adoption records/products and schema readers, ensure every promised capability links to tests and every exclusion is visible.
- Exclusions: Automatic release/tag/push/merge, grandfathered DocC plugin, compatibility with POC fixtures, marking incomplete or unresolved work complete.
- Checkpoint: R; present the full initial-delivery review.
  Mark this plan Complete only when the outcome below is delivered; publication/release is a separate owner-authorized operation.

## Explicitly deferred work

External contribution guidance (`CONTRIBUTING.md`) is deferred until preparation for the 0.1 release, as requested by the owner on 2026-09-07.
Until then, keep internal workflow and setup instructions in `AGENTS.md`, `README.md`, and this plan; implementation units must not recreate a separate contribution guide.

Do not implement these as preparation for later units:

- Playback acceleration, manual/immediate/fully virtual time, explicit cross-track constraints, global task-quiescence inference, configurable forced teardown.
- Scenario named values, automatic pseudonyms, cross-system alias resolution, encryption/secret management, generic reflective sanitizers or raw-value logs.
- Semantic JSON canonicalization/matching, JSON-path body sanitizer design, message/subtree overrides, reusable groups, cardinality ranges, alternative continuation trees, seeded random/distribution APIs or cursor rewinding.
- Arbitrary replacement execution engines, a second HTTP client, cross-client fixture portability, universal HTTP error taxonomy or wire/proxy/TLS internals.
- URLSession upload/download/resume/body-stream/WebSocket/stream/background tasks, task conversion, caching/cookie-store snapshots, metrics/progress/KVO, custom platform-security challenges, informational responses, hidden retries, protocol upgrades, server push and unvalidated platforms.
- Additional Core Location services listed in DD16, a live Linux location source, or globally shape-preserving route relocation.
- Optimistic concurrent publication, recording-duration locks, schema migration commands/frameworks, unhealthy recovery artifacts, speculative lazy/incremental raw spooling, additional text formats, POC importers and compatibility shims.
- Speculative Swift Algorithms/Async Algorithms/SwiftScream packages or build tools.
  The clean slate does not inherit the POC's swift-docc-plugin approval.

## Completion criteria

The complete initial outcome requires all of the following, with review records for the units above:

1. Q1–Q5 are resolved wherever required, with approved decision/policy changes recorded.
   No unresolved failed capability is hidden behind conditional code.
2. A reusable definition starts independent concurrency-safe executions; the public consumer boundary is proved outside first-party modules.
   All modes, typed tracks, prepared admission, atomic claims, reports, and lifecycle rules satisfy DD01–DD10.
   Core has no HTTP, test-framework or native-adapter dependency.
3. Random is a supported first-party product with file round-trip and all DD13 failure/concurrency behavior.
   Scheduler, clock and location meet DD14–DD16, including portable location replay and the bounded Apple facade/live source.
4. HTTP and URLSession meet DD11/DD12/DD17 with the full reviewed native matrix, recursive lifecycle, exact editable bodies, resource atomicity, correct re-record correspondence and one cross-platform system/schema.
   Required redirects/Basic/Digest/delegate behavior is delivered or its boundary has an explicit owner-approved amended decision, never an implicit omission.
5. File persistence is optional, deterministic, versioned, validated and logically atomic; unhealthy publication preserves the old scenario.
   Compatibility and golden fixtures protect every first-party schema.
   Ignoring affects verification only, and neither replay nor migration-on-read writes to persistence.
6. Explicit/scoped finish and opt-in test integrations expose complete outcomes; they cannot leave Diorama-owned replay callbacks running after quiescence or alter consumer-owned live behavior merely to end recording.
   Later misuse is separately inspectable without changing the final report or retaining execution machinery; test reporting respects the test context's lifetime.
7. Canonical quality checks and required macOS/iOS Simulator/Linux jobs pass, debug/release strict compilation and public documentation are warning-free, every expected coverage upload succeeds, and pins/adoption records/update automation satisfy the delivery policies.
   Unavailable checks remain gaps.
8. Documentation and plan status reflect delivered behavior and exclusions.
   Owner scope confirmation, complete branch review, and separate PR/merge approvals are honored at every unit; completing this plan never itself authorizes a release, merge, or continuation.
