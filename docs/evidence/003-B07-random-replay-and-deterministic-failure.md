# 003-B07: Random replay and deterministic failure

- Date: 2026-09-13
- Authority: Owner confirmation of 003-B07's scope and GPT-5.6 Terra at `high`
  reasoning, with explicit authorization to develop it as a stacked unit atop
  rebased B06.
- Status: Complete; owner review feedback addressed and pull request creation
  authorized on 2026-09-16.
- Prerequisites: [B06 evidence](003-B06-random-recording-and-passthrough.md),
  [DD05](../design-decisions/05-consumption-and-verification.md), and
  [DD13](../design-decisions/13-random-proving-system.md).

## Review boundary

This unit completes in-memory random replay through the public typed
`SequentialTrackLease` boundary established by B04 and exercised from an
external module in B05. It changes no `DioramaCore` source, public core API,
dependency, persistence schema, timing model, or random distribution behavior.

`DioramaRandomSystem` now prepares the declared values track in replay mode and
activates a private replay generator that has no source field. Record and
passthrough use a separate private live generator whose source is non-optional
and whose mode cannot represent replay. Both implementations are exposed only
as `any RandomNumberGenerator & Sendable`. The source factory is therefore
neither evaluated nor retained by replay activation.

## Replay and failure behavior

- Replay atomically returns each prepared `UInt64` in track order. The shared
  reference-semantic generator and the lease share one cursor; fresh executions
  receive fresh cursors.
- Empty or exhausted replay calls use the existing public `claimNext()` failure
  boundary. It retains the structured serious replay fact before notifying the
  configured sink, including the requested record identity and available count.
  If notification returns, `next()` returns zero. It never substitutes a live
  random value.
- Repeated exhausted calls receive distinct, monotonically increasing requested
  positions. Concurrent calls cannot claim a value twice.
- Calls after `finish()` use the established distinct closed-lease lifecycle
  diagnostic and return zero. Replay remains offline; record and passthrough
  also remain offline after their live sources have been released.
- Consumers retrieve the standard-library protocol existential rather than a
  public Diorama implementation type. Because `next()` is a mutating protocol
  requirement, a directly invoked existential is bound with `var`; concurrent
  callers copy the existential into task-local variables while sharing the
  reference-backed attachment cursor.
- Remaining replay values are not eagerly consumed. B08 owns final immutable
  usage and unused-value reporting, rather than adding a random-specific
  finalization path in this replay unit.

No looping, last-value reuse, manual rewind, task-identity assignment,
cryptographic claim, unsafe sendability annotation, or third-party dependency
was added.

## Verification

- The focused `swift test --filter DioramaRandom -Xswiftc -warnings-as-errors`
  gate passes 13 random tests. The new replay suite covers zero and maximum
  `UInt64`, a counting source factory, a trapping factory that cannot be
  evaluated, empty/exhausted continuation, ordered sink delivery, fresh
  executions, 100 concurrent claims with no duplicate values, and escaped
  generators in all three modes.
- `scripts/check` was run after the implementation and passed formatting,
  strict lint, warnings-as-errors host tests, and release compilation. A later
  source-file split addressed the initial file/type-length lint findings; the
  rerun strict lint gate passed with zero violations. The final pre-review
  canonical check is recorded with the branch diff below.
- `scripts/coverage ios` passes the release build and all 62 current tests on
  the selected iPhone 17 / iOS 27.0 simulator while compiling with the iOS 18
  deployment target. The result bundle contains the coverage report and no test
  failures.
- `scripts/coverage swiftpm linux` passes the host SwiftPM coverage export and
  writes `.build/coverage/linux.json`. That local command labels the output but
  does not itself provide native Linux evidence; the required digest-pinned
  hosted Linux check provides that platform evidence for the merge revision.
- `git diff --check` and the final complete branch diff against B06 are clean.

## Review handoff

The proposed implementation commit contains the replay path and its proving
tests. This evidence and the Plan 003 status update form a separate
documentation commit. Required hosted Quality, macOS, iOS, Linux, and Codecov
checks pass for the merge revision.
