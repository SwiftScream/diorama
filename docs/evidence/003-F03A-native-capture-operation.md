# 003-F03A: Native capture refactor assessment

- Status: Abandoned
- Recorded: 2026-10-07
- Authority: After reviewing the caller changes, the owner requests discarding
  the implementation branch and abandoning the unit as unfruitful.
- Plan: [F03A](../plans/003-clean-slate-implementation.md#003-f03a--shared-native-capture-and-recording-operation).
- Prototype base: `master` at `2199d82`.
- Discarded branch: `003-f03a-native-capture-operation`.

## Intent and result

The unit aims to reduce the code a system author needs to implement recording.
The prototype adds `recordNative` and a typed native/recording outcome to Core,
then migrates Random and WallClock to it. It centralizes native-return
preservation, conversion, preparation, and recording failure classification.

The measured first-party reduction is modest:

| Caller | Net source-line reduction |
| --- | --- |
| Random | 10 |
| WallClock, across its capture helper and live facade | 2 |
| Total | 12 |

These raw source-line counts include all changed first-party caller files.
The prototype also adds a 106-line Core file, changes lease bookkeeping, and
introduces a public outcome type that callers must unpack. Much of the caller
code remains because source serialization, ownership, lifetime, fallback, and
clock progress stay system-owned. WallClock's helper simplification largely
moves bookkeeping into its caller.

The prototype passes local macOS, iOS Simulator, and Linux verification, with
338 tests in each full platform run and a focused iOS check after test-worker
isolation. That evidence establishes correctness of the tested implementation;
it does not establish enough system-authoring benefit to justify the new API.

## Owner disposition

Discard the unmerged implementation branch and retain the recording APIs
already on `master`. No prototype production code, tests, or API guide changes
are adopted. This document retains the assessment, rather than presenting the
discarded API as delivered functionality.

F03A is no longer required for Phase F or Plan 003 completion. F05 remains the
next planned unit because its F04/C05 prerequisites are complete and it has no
dependency on F03A. Revisiting a shared recording convenience requires a new
owner-confirmed scope and a demonstrated, material reduction in complete
caller implementations before adopting another public Core surface.
