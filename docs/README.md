# Diorama documentation

This directory contains the accepted design and delivery policies for the
clean-slate Diorama implementation. It intentionally excludes standalone
documentation for the earlier `swift-network-snapshot` proof of concept.

The owner approved the consolidated design and implementation plan on
2026-09-07. Implementation has not started.

## Reading order

1. [Design overview](design-overview.md)
2. [Design decision index](design-decisions/README.md)
3. [Plan index](plans/README.md)
4. [Approved implementation plan](plans/003-clean-slate-implementation.md)
   (each unit requires owner scope confirmation before implementation)
5. [Dependency approval policy](dependency-policy.md)
6. [Quality gates and CI policy](quality-gates-and-ci.md)

Read the individual decisions referenced by an implementation-plan item before
working on it. The design overview summarizes their combined architecture but
does not replace their detailed contracts.

## Decision process

- [Plan 001](plans/001-design-decision-process.md) records how the first twelve
  architectural questions were discussed and approved.
- [Plan 002](plans/002-follow-up-design-decisions.md) records the delivery
  policies and Decisions 13 through 17 that closed the synthesis prerequisites.
- [Plan 003](plans/003-clean-slate-implementation.md) defines atomic implementation
  units and records remaining gates; its status is Approved as of 2026-09-07.
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

## Delivery policies

- [Dependency approval policy](dependency-policy.md) requires approval before a
  third-party package enters production use and records the initial candidate
  set.
- [Quality gates and CI policy](quality-gates-and-ci.md) defines Swift and Xcode
  posture, formatting and linting through Mint, GitHub Actions, platform tests,
  strict concurrency, Codecov, action pinning, and Dependabot.

## Historical boundary

The POC repository remains available separately as implementation evidence. Its
source tree, package shape, Foundation wrappers, persistence implementation, and
tests are not inputs that the clean-slate implementation must preserve.

References to the POC inside accepted decisions remain because they explain why
particular alternatives were rejected. They do not create compatibility
requirements.
