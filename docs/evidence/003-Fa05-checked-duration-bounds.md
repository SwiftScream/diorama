# 003-Fa05: Checked logical-time operand bounds

- Date: 2026-10-11
- Status: Complete.
- Plan: [003-Fa05](../plans/003-clean-slate-implementation.md#003-fa05--checked-logical-time-operand-bounds)
- Authority: The owner-approved Fa stack; current session model/settings.

## Fix and audit

Checked logical addition now bounds each operand before reading
`Duration.components`. Checked elapsed time bounds the later operand and
requires `0 <= earlier <= later`, so both operands fit before extraction.
The existing checked result arithmetic remains unchanged. `ExecutionTime`
therefore reports overflow instead of trapping for an oversized positive delay;
negative delays still report their existing negative-delay failure.

The audit covers both shared-helper callers, scheduling's existing operand and
host-deadline checks, and the execution clock's separate standard `Clock`
preconditions. No standard clock arithmetic contract or scheduling policy changes.

## Reproduction and verification

An isolated executable containing the unfixed helper calls
`Duration.zero.checkedLogicalTime(adding: .seconds(Int64.max) * 2)`.
With core dumps disabled, it terminates with signal 5 and the Swift diagnostic
`Not enough bits to represent the passed value`. This reproduces the original
component-extraction trap outside the test runner.

Focused tests and `scripts/check` pass on Apple Swift 6.4 / Xcode 27.0: 384
tests, formatting, strict lint, warnings-as-errors debug/release builds, and
both examples. The public regression uses ordinary imports and the existing
consumer timed system. It checks overflow diagnostics, negative-delay behavior,
zero and fractional delays, and retained final-report facts.

Direct helper tests cover the inclusive maximum, one attosecond beyond it,
twice `Int64.max` seconds, each operand position, bounded-result overflow,
negative values, zero, fractional seconds, and elapsed differences that would
fit despite invalid operands. Existing execution-time, scheduler, and clock
tests retain their assertions.

`scripts/coverage ios` passes from an isolated copy of this unit: iOS 18
deployment-target release compilation, 383 tests on iPhone 17 / iOS 27.0,
and LCOV export. The pinned Swift 6.4 Ubuntu x86_64 container, two CPUs and
4 GB, passes `scripts/test --enable-code-coverage`: 384 tests, release builds,
and examples. It reuses the task-owned Linux compilation cache and replaces
source inputs before building. Both platform gates include the public crash
regression and existing scheduler/clock suites.

Required PR checks cover formatting/lint, macOS/iOS/Linux execution, and
Codecov uploads. The local runs above do not establish minimum-platform runtime
coverage.
