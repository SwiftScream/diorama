# 003-F04 sequential wall replay and exhaustion

F04 adds wall replay to the first-party clock attachment. A replay handle claims
and consumes the attachment's stored values through its Core sequential
lease's `consumeNext()` operation, then extracts their effective dates.
It does not activate the live source factory. Repeated and backward dates are
returned as stored, with no delay between observations.

The [preparatory Core refactor](003-F04-replay-continuation-preparation.md)
returns stored `OverridableValue<Date>` values, preserving authorship in Core.
The clock extracts each effective `Date` for its consumer and selects
`.replayLast(defaultValue: .observed(unixEpoch))` at lease creation. Core has no
projection closure, separate replay representation, or third lease generic
parameter. The default wrapper is transient and never becomes a stored record.

When a claim exhausts the track, Core retains a structured replay exhaustion
diagnostic. The nonthrowing wall facet returns the last successfully claimed
date, or Unix epoch when the track contains no claims. Once execution
finalization closes the lease, an escaped handle similarly continues from its
last date and Core records the lifecycle diagnostic. Passthrough and record
handles also retain their last native date after close. Replay consumption and
continuation selection share the lease's atomic order. `ReplayWallClock` has
no separate mutex, position counter, or cached date. An exhausted concurrent
read sees the last consumed value even when that successful caller has not yet
returned. Diagnostic handlers run after the lease lock is released.

An empty declared wall track is valid and exhausts at runtime. A missing
required named track fails attachment startup. Separate named attachments use
independent replay cursors. Core finalization reports unclaimed records and
consumed claims; F04 adds no duplicate accounting path. Returning a wall value
completes its recorded behavior, so it requires no later acknowledgement.

## Verification

The 2026-10-07 preparatory refactor and clock adoption use stored values,
system-owned translation, and lease-owned continuation. Regression assertions prove that returned wall values
are consumed, unread observations remain available to finalization evaluation,
and authored overrides survive replay unchanged.

- `swift test -Xswiftc -warnings-as-errors --filter 'WallReplayTests|WallSourceTests|ReplayContinuation'`:
  38 tests passed: 14 Core continuation tests and 24 wall tests, including
  10 replay tests for source factory isolation, empty versus absent tracks,
  exhaustion, keyed tracks, exact concurrent continuation, authored values,
  and escaped handles with and without prior reads.
- `scripts/check`: formatting, strict lint, all 319 tests, debug and release
  builds, and example verification passed on macOS.
- `scripts/coverage swiftpm macos`: all 319 tests passed and macOS LCOV
  coverage export completed.
- `scripts/coverage ios`: all 319 tests passed on the iPhone 17 iOS 27.0
  simulator; the package deployment target remains iOS 18.0. LCOV coverage
  export completed.
- `scripts/coverage swiftpm linux` in the pinned x86_64 Swift container:
  all 319 tests, release builds, example execution, and Linux LCOV export
  passed. The container command exited successfully.
- Local macOS and iOS LCOV reports each cover all 85 changed executable source
  lines relative to the F04 base (`80aec56`). Codecov computes its own patch metric
  from the hosted platform uploads.

The emulated Linux example emits `safeExec` warnings for signals 32 and 33;
the example and coverage command still exit successfully.

The simulator and Linux image verify current CI environments, not execution on
the minimum iOS deployment runtime.
