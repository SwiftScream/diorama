# Plan 002: Follow-up design decisions

- Status: Complete
- Created: 2026-09-05
- Completed: 2026-09-06
- Preceded by: [Plan 001: Design decision process](001-design-decision-process.md)
- Outcome: [Accepted Decisions 13 through 17](../design-decisions/README.md)

This is a completed process record. It is not an active implementation plan.

## Purpose

The first twelve design decisions establish Diorama's common architecture and
URLSession direction. Their [design review](../design-overview.md) found no
contradiction requiring a decision to reopen, but identified deliberately
deferred work that must be resolved before synthesizing a complete clean-slate
implementation plan.

This document orders that discussion. As with the original decision process,
one topic is reviewed at a time. Product decisions receive their own decision
notes and explicit owner approval. Delivery policies are recorded separately
because they govern how implementation work is accepted rather than Diorama's
runtime semantics.

## Delivery policies

### 1. Dependency governance

Status: Accepted.

The [dependency approval policy](../dependency-policy.md) requires approval
before a third-party Swift package becomes part of accepted implementation
work. It allows isolated exploration, defines the approval unit and upgrade
boundary, and records initial approved candidates.

### 2. Quality gates and CI

Status: Accepted. See
[Quality gates and CI policy](../quality-gates-and-ci.md).

Select formatting and linting behavior, the canonical local verification
entry point, CI provider and triggers, macOS and Linux jobs, Swift and Xcode
versions, and rules for warnings or generated output. The resulting policy
must make repository bootstrap and its checks an early implementation task.

## Follow-up design decisions

### 13. Minimal proving system and extension boundary

Status: Accepted. See
[Decision 13: Random proving system and extension boundary](../design-decisions/13-random-proving-system.md).

Decide whether a random-number system is the first vertical implementation
slice, its stable and native APIs, replay-exhaustion behavior for a nonthrowing
operation, and whether it ships as a first-party product. Fix the minimum
consumer system extension surface available in the initial milestone.

The leading proposal records sequential raw `UInt64` results from an injected
`RandomNumberGenerator`. It exercises setup, modes, stable conversion,
selection, atomic consumption, persistence, diagnostics, and finalization
without requiring networking or logical-time scheduling.

### 14. Initial real-time replay scheduler

Status: Accepted. See
[Decision 14: Initial real-time replay scheduler](../design-decisions/14-real-time-replay-scheduler.md).

Specify the monotonic clock and timer tolerance, deterministic ordering at equal
deadlines, task registration, mixed record/replay timing, finalization, and the
relationship between synchronous clock operations, sleepers, streams, and
interaction phases.

Logical time initially maps one-to-one to real time. Constant-factor
acceleration is the leading next enhancement. Manual advancement, fully virtual
time, and explicit cross-track constraints remain outside the initial milestone
unless this discussion deliberately reopens that scope.

### 15. Initial clock system

Status: Accepted. See
[Decision 15: Initial clock system](../design-decisions/15-clock-system.md).

Choose the injected API and stable operation model. Distinguish wall-clock
observation from monotonic sleeping and scenario scheduling, define sleep
cancellation and nonthrowing replay failures, and establish portable platform
semantics.

### 16. Initial location system

Status: Accepted. See
[Decision 16: Initial location system](../design-decisions/16-location-system.md).

Define the portable location domain and injectable service, origin-relative
coordinate representation, subscription and error lifecycle, authorization and
availability boundaries, non-failable mismatch policy, and the Apple Core
Location adapter. Establish which pieces remain usable on Linux.

### 17. HTTP lifecycle composition

Status: Accepted. See
[Decision 17: HTTP lifecycle composition](../design-decisions/17-http-lifecycle-composition.md).

Select the concrete non-duplicating stable shape for response heads, complete
or partial bodies, delivery segmentation, success/failure/open conclusions,
redirects, authentication, and URLSession-specific supplements. Preserve the
one-system portability rule across Foundation and FoundationNetworking.

## Synthesis gate

Status: Satisfied.

All follow-up discussions are accepted. Plan number 003 is reserved for the
clean-slate implementation plan. Required URLProtocol and platform spikes
remain implementation tasks and do not substitute for the accepted semantics
above.
