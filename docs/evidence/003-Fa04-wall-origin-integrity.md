# 003-Fa04: Portable wall-origin persistence integrity

- Date: 2026-10-11
- Status: Complete.
- Plan: [003-Fa04](../plans/003-clean-slate-implementation.md#003-fa04--portable-wall-origin-persistence-integrity)
- Authority: DD15's owner-approved fixed numeric range and the approved Fa stack.

## Contract and implementation

`StableTimeCodec.roundedToMillisecond` checks inclusive Unix-second bounds
`-62_135_500_000...253_402_250_000` after existing rounding. The named constants
carry Foundation-verified UTC comments. No calendar-derived limit, display-zone
condition, or production format/reparse validation is introduced.

Formatting, parsing, strict wall construction, capture, authored values, and
prepared Date admission share that check. Date's scalar admission policy rejects
unsupported already-prepared values before activation. Whole-track relationships
remain the separate Fa03 unit. Unsupported live reads preserve their native
return and continuation, diagnose conversion failure, and refuse publication.

Old calendar-year endpoint goldens now belong to the rejection fixtures. The
merge regression uses individually supported dates whose merged result exceeds
the upper bound. The former huge-delta capture test now expects a diagnostic
for each observation rejected by the earlier date-range boundary.

## Verification

Focused scalar, persistence, and merge tests pass. `scripts/check` passes strict
formatting/lint, all 381 host tests, warnings-as-errors debug/release builds, and
both examples on the selected Apple Swift 6.4 / Xcode 27.0 toolchain.

The boundary test verifies 15,129 round trips: nine instants across all 1,681
supported whole-minute offsets, including both bounds, nearby milliseconds,
negative/positive Unix seconds, UTC, and both 14-hour extremes. Separate tests
cover rounding into the inclusive bounds, remaining outside them, nonfinite
values, the reported 100,000,000,000,000-second regression, prepared baselines,
authored shifts, cumulative values, decoder rejection, healthy file replay,
native failure returns, and byte-identical preservation of the previous file.

`scripts/coverage ios` passes: iOS 18 deployment-target release compilation,
380 tests on iPhone 17 / iOS 27.0, and LCOV export. The pinned Swift 6.4
Ubuntu x86_64 image, two CPUs and 4 GB, passes `scripts/test
--enable-code-coverage`: all 381 tests, release builds, and both examples.
Linux runs in a task-owned writable `/work` cache with read-only source inputs;
subsequent units may reuse compilation products. Coverage export itself still
uses Fa07's isolated build command. Runtime `safeExec` signal-32/33 messages
appear under emulation; compilation and all assertions pass.

Required PR checks cover formatting/lint, macOS/iOS/Linux execution, and
Codecov uploads. The local runs above do not establish minimum-platform runtime
coverage.
