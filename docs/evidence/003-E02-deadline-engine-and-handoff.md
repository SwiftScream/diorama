# 003-E02: One-to-one deadline engine and deterministic handoff

- Scope and model setting confirmed: 2026-09-28
- Recommended setting: GPT-6 Astra, `xhigh` reasoning
- Status: Complete locally; owner review is the next checkpoint
- Owning unit: [003-E02](../plans/003-clean-slate-implementation.md#003-e02--one-to-one-deadline-engine-and-deterministic-handoff)
- Governing decision: [DD14](../design-decisions/14-real-time-replay-scheduler.md)

The owner authorized E02 above the E01 review branch while E01 completed
review. E02 remains a separate review unit.

## Delivered contract

`SystemPreparationContext.scheduling` provides a `SchedulingLease` for its
attachment. Absolute logical deadlines and nonnegative relative delays use
E01's origin and clock source. The core obtains attachment and track order
from the scenario definition; systems provide the record sequence. Identical
ordering keys use atomic registration order. Foreign and undeclared tracks
are rejected.

The execution starts one worker on its first registration. That worker owns
at most one clock wait, requests zero tolerance, replaces an earlier deadline,
and joins a canceled wait before creating its replacement. Wait identity
distinguishes a stale wake from the current timer. Every wake rechecks logical
time, and every due batch leaves the pending queue atomically before the first
handoff. Late wakes retain deadline, attachment, track/record, and registration
order. Synchronous handoffs run serially outside scheduler isolation.

Past deadlines, including negative offsets before the execution origin, and
zero delays join the next drain. A callback can synchronously register more
work without reentrant handoff; the entire current batch precedes that work.
Swift tasks resumed by handoffs retain their own executor scheduling semantics.

The narrow lifetime integration needed to own this worker closes admission,
releases pending captures outside locks, cancels and joins the timer, and
awaits claimed synchronous handoffs before adapter cleanup and report freezing.
Tests hold a handoff across finish and use destruction of a separate pending
capture to observe closure without a timing assumption. Startup rollback and
escaped leases also refuse new work.

The [public scheduling contract](../execution-scheduling.md) explains this
synchronous handoff boundary. Per-item cancellation, cancellation-versus-claim
races, and explicit acknowledgements for delivery on other actors or queues
remain E03 work. E02 does not advertise completion tracking for tasks launched
by a handoff.

## Arithmetic and safe failure

Negative relative delays and checked addition overflow produce retained
diagnostics before admission. Absolute past runtime deadlines remain valid.
An absolute duration outside the supported positive logical range is rejected
before decomposing it into `Int64` seconds.

A local standalone probe found that `ContinuousClock.sleep` traps when a
deadline exceeds its timestamp's `Int64` seconds range: adding
`.seconds(Int64.max)` to `clock.now` is representable as a Swift instant but
traps during native timer timestamp conversion. Registration therefore checks
the mapped deadline against the clock epoch and timer range before creating
any wait. The public regression test covers both logical addition overflow
and overflow introduced by the nonzero execution origin.

Backward clock readings and unexpected internal wait failures stop pending
delivery and retain bounded scheduling facts. No underlying clock error or
host instant is reported. Active scheduling diagnostics participate in
`noUnexpectedOperations`; late misuse remains separate from the frozen report.

## Verification

Apple verification uses Xcode 27.0 (`27A266a`), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), and macOS 27.0.

| Gate | Local result |
| --- | --- |
| Refactor commit exported independently; focused `ExecutionTimeTests` | Pass: seven tests. |
| Focused scheduler, lifetime, and claimed-handoff tests | Pass: 13 tests, including parameterized clock-failure and real-clock cases. |
| `scripts/check` | Pass: pinned formatting and strict lint, host tests, release library and example builds, and example execution. |
| `scripts/coverage swiftpm macos` | Pass: full tests, release checks, and LCOV export. |
| `scripts/coverage ios` | Pass: iOS 18 deployment-target build, iPhone 17 / iOS 27.0 Simulator tests, and LCOV export. |
| Pinned Linux container; `scripts/coverage swiftpm linux` | Pass: full tests, release library and example builds, example execution, and LCOV export. |

Linux uses the [quality policy's pinned Swift 6.4 image](../quality-gates-and-ci.md#local-entry-points)
on x86_64 with two CPUs and 4 GB of memory. Package inputs are copied from a
read-only source mount. The example launcher emits the same nonfatal SwiftPM
`safeExec` signal 32/33 warnings recorded in E01, then completes its assertions.

A local comparison of changed executable lines against the E01 base measures
264 of 274 covered lines (96.35%) on macOS and iOS, and 262 of 274 (95.62%) on
Linux. These LCOV measurements exceed the policy's 90% patch threshold; the
hosted Codecov result remains the PR's authoritative coverage gate.

The injected clock suite covers all ordering keys using declaration order that
differs from lexical order, equal keys, late and early wakes, replacement of
the earliest wait, complete-batch claims, callback reentry, zero and past
deadlines, concurrent admission, range rejection, clock failure, and pending
capture release. Real-clock cases check no early handoff and a tolerant
five-second upper bound. They make no assumptions about resumed-task order.

Local Apple tooling requires ordinary cache access outside the workspace. The
simulator evidence proves iOS 18 API availability and behavior on iOS 27.0;
it does not measure an iOS 18 runtime. Hosted CI and Codecov upload evidence
are obtained through the separately authorized PR workflow.

## Review boundary

No production dependency, persistence field, playback-rate control, public
host instant, virtual/manual clock, detached task, or unsafe isolation
annotation is introduced. Scheduling leaves record/replay track claims and
usage unchanged. The initial queue uses sorted array insertion; no large-load
performance guarantee is established. A synchronous handoff that never
returns prevents finish, as required by DD14's lifetime constraint.
