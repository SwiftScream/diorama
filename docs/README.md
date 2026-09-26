# Diorama documentation

This directory contains the accepted design and delivery policies for the
clean-slate Diorama implementation. It intentionally excludes standalone
documentation for the earlier `swift-network-snapshot` proof of concept.

The owner approved the consolidated design and implementation plan on
2026-09-07. Implementation is in progress under Plan 003.

## Reading order

1. [Design overview](design-overview.md)
2. [Design decision index](design-decisions/README.md)
3. [Plan index](plans/README.md)
4. [Approved implementation plan](plans/003-clean-slate-implementation.md)
   (each unit requires owner scope confirmation before implementation)
5. [Dependency approval policy](dependency-policy.md)
6. [Quality gates and CI policy](quality-gates-and-ci.md)
7. [JSON persistence schema version 1](persistence-schema-v1.md)

Read the individual decisions referenced by an implementation-plan item before
working on it. The design overview summarizes their combined architecture but
does not replace their detailed contracts.

## Decision process

- [Plan 001](plans/001-design-decision-process.md) records how the first twelve
  architectural questions were discussed and approved.
- [Plan 002](plans/002-follow-up-design-decisions.md) records the delivery
  policies and Decisions 13 through 17 that closed the synthesis prerequisites.
- [Plan 003](plans/003-clean-slate-implementation.md) defines atomic implementation
  units and records remaining gates; its status is In progress.
- [Plan index](plans/README.md) distinguishes actionable plans from completed
  traceability records.
- [Design decisions](design-decisions/README.md) is the authoritative status and
  document index.
- [Design overview](design-overview.md) is the maintained synthesis of the
  accepted decisions.

The accepted decisions cover the common scenario abstraction, system semantics,
recorded behavior, replay selection, consumption, stable conversion,
persistence, schema evolution, transformation, lifecycle ownership, HTTP,
URLSession, the proving system, scheduling, clocks, location, and concrete HTTP
lifecycle composition.

[Decision 18: Diorama setup and immutable scenario data](design-decisions/18-diorama-setup-and-scenario-data.md)
refines the runtime and persistence boundaries with one semantic definition
model, reusable typed setup, and first-class in-memory recording results. It
includes the random, URLSession, and location API design example and reconciles
the earlier decisions explicitly.

## Delivery policies

- [Dependency approval policy](dependency-policy.md) requires approval before a
  third-party package enters production use and records the initial candidate
  set.
- [Quality gates and CI policy](quality-gates-and-ci.md) defines Swift and Xcode
  posture, formatting and linting through Mint, GitHub Actions, platform tests,
  strict concurrency, Codecov, action pinning, and Dependabot.

## Implementation evidence

- [Toolchain and deployment availability](evidence/003-A01-toolchain-and-availability.md)
  records 003-A01's exact toolchain and platform selections, isolated probes,
  observed results, and remaining environment verification gaps.
- [Quality-tool adoption record](evidence/003-A02-quality-tool-adoptions.md)
  records the Mint, SwiftFormat, SwiftLint, and GitHub Actions adoption review.
- [Package skeleton evidence](evidence/003-A03-package-skeleton.md) records the
  minimal package boundary, local build/test results, and deferred bootstrap gates.
- [Quality and CI bootstrap evidence](evidence/003-A04-quality-and-ci-bootstrap.md)
  records the canonical local gate, platform workflows, coverage, and update
  automation.
- [Typed scenario definition evidence](evidence/003-B01-typed-scenario-definitions.md)
  records the first public core boundary, its validation behavior, and
  cross-platform verification.
- [Deployment-minimum evidence](evidence/003-B02-deployment-minimums.md)
  records the owner-approved macOS 15/iOS 18 floors needed for a shared
  standard-library mutex implementation.
- [Prepared admission and diagnostic evidence](evidence/003-B02-prepared-admission-and-diagnostics.md)
  records typed preparation, safe reporting, callback isolation, recording
  health, and reporter ownership.
- [Execution and lease-lifetime evidence](evidence/003-B03-execution-and-lease-lifetime.md)
  records ordered startup, rollback, explicit finish, and escaped-handle
  ownership for sequential systems.
- [Atomic sequential-operation evidence](evidence/003-B04-atomic-sequential-operations.md)
  records reservation-ordered appends, atomic single-use replay claims, and
  mode-safe operation diagnostics.
- [Consumer-module extension evidence](evidence/003-B05-consumer-module-extension-proof.md)
  records the external-module, public-only proof for a consumer-defined
  synchronous sequential system.
- [Random recording and passthrough evidence](evidence/003-B06-random-recording-and-passthrough.md)
  records the first-party random system's serialized live-source behavior,
  reference and attachment ownership, and cross-platform verification.
- [Random replay and deterministic-failure evidence](evidence/003-B07-random-replay-and-deterministic-failure.md)
  records offline raw-value claims, deterministic exhaustion, lifecycle
  continuation, and source-isolation verification.
- [Typed dependency-key evidence](evidence/003-B07A-typed-dependency-keys.md)
  records typed system construction and erasure, exact attachment lookup, public
  consumer extensibility, and migration of the random setup contract.
- [Concurrent finalization and evaluation evidence](evidence/003-B08-concurrent-finalization-and-evaluation.md)
  records immutable usage, explicit evaluation, safe rendering, cancellation,
  diagnostic freeze races, and escaped-reporter ownership.
- [Scoped execution convenience evidence](evidence/003-B09-scoped-execution-convenience.md)
  records typed variadic dependency injection, both-outcome finalization,
  cancellation, actor isolation, and compiler-regression verification.
- [First production coverage baseline](evidence/003-B10-first-production-coverage-baseline.md)
  records the owner-confirmed baseline-relative project tolerance, patch target,
  platform evidence, and retained upload requirements.
- [In-memory random usage example](evidence/003-B11-random-usage-example.md)
  records the public-only executable example, its explicit replay-baseline
  boundary, and compilation evidence.
- [Persistent-system registration evidence](evidence/003-C01-persistence-registration.md)
  records the optional format-neutral `Codable` dispatch boundary, explicit
  schema-version readers, registration validation, and platform evidence.
- [Deterministic JSON and random-schema evidence](evidence/003-C02-deterministic-json-and-random-schema.md)
  records the strict version-one envelope, first-party random payload,
  canonical fixtures, compatibility rejection, and platform evidence.
- [Atomic file repository evidence](evidence/003-C03-atomic-file-repository.md)
  records the byte-storage boundary, load outcomes, path rules, atomic
  replacement, failure preservation, and backend limitations.
- [Baseline-loading evidence](evidence/003-C04-baseline-loading-before-activation.md)
  records repository-backed startup, the complete load-result/effective-mode
  policy, pre-activation replay refusal, and record rebuilding diagnostics.
- [Semantic model and codec migration evidence](evidence/003-C04A-semantic-model-and-codec-migration.md)
  records data/policy separation, the direct definition codec boundary, and
  unchanged JSON compatibility and execution behavior.
- [Reusable typed setup evidence](evidence/003-C04B-reusable-typed-setup.md)
  records the consumer `Diorama` module, direct run and scoped result API, shared
  optional capabilities, baseline constructors, and registry-based omission.
- [Candidate replacement and publication evidence](evidence/003-C05-candidate-replacement-and-publication.md)
  describes complete semantic results, mixed-mode preservation, optional atomic
  publication, and the associated verification evidence.
- [Publication failures and reports evidence](evidence/003-C06-publication-failures-and-reports.md)
  describes safe stage-specific reports, prior-document preservation evidence,
  and fault-injection verification.
- [Persisted consumer and random conformance evidence](evidence/003-C07-persisted-consumer-and-random-conformance.md)
  records the external-module codec, complete random file workflow, example
  execution, and cross-platform verification.
- [URLSession interception spike evidence](evidence/003-D01-urlsession-interception.md)
  records the bodyless GET matrix across macOS, iOS Simulator, and Linux,
  including the Linux routing gaps and request-field collision observation.
- [URLSession task rejection evidence](evidence/003-D02-task-rejection-and-response-presentation.md)
  records native rejection points, diagnostic delivery, response buffering and
  disposition behavior, and the remaining response-presentation questions.
- [URLSession delivery and delegate-boundary evidence](evidence/003-D02-delivery-and-delegate-boundaries.md)
  covers native resume data, timed delivery, cache-policy enforcement, and
  task-delegate visibility and interception hooks.
- [URLSession task and response capability matrix](evidence/003-D02-completion-and-capability-matrix.md)
  consolidates constructor, body-forwarding, rejection, and delegate findings
  with the bridge requirements they establish.
- [FoundationNetworking investigation handoff](evidence/003-D02-foundationnetworking-handoff.md)
  consolidates D01–D03 findings, source locations, reproductions, accepted
  platform limitations, and their effect on the planned URLSession bridge.
- [URLSession redirect correlation evidence](evidence/003-D03-redirect-correlation.md)
  covers task ownership across redirect instances, native request derivation,
  current redirect decisions, forwarding, timing, and upstream redirect gaps.

## Historical boundary

The POC repository remains available separately as implementation evidence. Its
source tree, package shape, Foundation wrappers, persistence implementation, and
tests are not inputs that the clean-slate implementation must preserve.

References to the POC inside accepted decisions remain because they explain why
particular alternatives were rejected. They do not create compatibility
requirements.
