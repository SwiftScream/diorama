# 003-E01: Execution logical-time and capture service

- Scope and model setting confirmed: 2026-09-23
- Recommended setting: GPT-6 Sol, `high` reasoning
- Status: Complete locally; owner review is the next checkpoint
- Owning unit: [003-E01](../plans/003-clean-slate-implementation.md#003-e01--execution-logical-time-and-capture-service)
- Governing decisions: [DD03](../design-decisions/03-recorded-behaviors.md),
  [DD06](../design-decisions/06-runtime-to-snapshot-conversion.md), and
  [DD14](../design-decisions/14-real-time-replay-scheduler.md)

The owner authorized E01 while C07 review proceeds concurrently. This branch
starts from the C07 feature-branch commit and contains E01 as a separate review
unit. Any C07 review changes may require restacking this branch before a PR.

## Delivered contract

`SystemPreparationContext.time` gives every attachment in one execution the
same `ExecutionTime` service. It captures one origin after all systems activate
and before startup returns. The default source holds one `ContinuousClock`
value for that execution; an internal source injection makes origin and
observation behavior deterministic in tests.

Systems can read logical `Duration`, reserve an opaque `LogicalTimeCapture` at
an observation boundary, compare capture order, derive an elapsed duration,
and add a nonnegative delay to a capture with checked arithmetic. Tokens are
execution-local and have no stable or `Codable` representation. A later
conversion cannot change their time or order. No track receives a generic
timestamp, and the random system remains untimed.

The service reports typed, safe diagnostics for pre-start or closed reads,
foreign or reversed captures, a backward clock source, negative delays, and
overflow. Finish closes new observations while retaining already captured
tokens for pure inspection. Invalid active operations participate in opt-in
`noUnexpectedOperations` evaluation; post-finish diagnostics remain separate
from the immutable final report. The consumer publication report classifies
new time diagnostics under recording.

The public contract is described in [Execution logical time](../execution-time-service.md).

## Verification

| Gate | Local result |
| --- | --- |
| Focused `ExecutionTimeTests` | Seven tests pass on macOS. |
| `scripts/check` | Pass: strict formatting and linting, host tests, release library build, release example build and execution. |
| `scripts/coverage swiftpm macos` | Pass: tests, release builds, example execution, and LCOV export. |
| `scripts/coverage ios` | Pass: iOS 18 deployment-target build, iPhone 17 / iOS 27 Simulator tests, and LCOV export. |
| Pinned Linux container running `scripts/coverage swiftpm linux` | Pass: tests, release builds, example execution, and LCOV export. |

The local macOS check needed ordinary user-cache access for SwiftLint. The
iOS gate tests on the available iOS 27 simulator while compiling for the iOS 18
deployment target; it does not measure behavior on an iOS 18 runtime.
The Linux example emitted two nonfatal SwiftPM `safeExec` signal warnings and
completed its assertions.

## Review boundary

E01 adds no deadline queue, timer delivery, public host instant, playback
control, stable schema field, third-party dependency, or unsafe isolation
annotation. The shared service is available to systems in all attachment
modes; capability-specific accumulation and scheduling remain in later E units.
