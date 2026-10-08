# 003-F07: Clock composition and platform conformance

- Date: 2026-10-08
- Status: Complete.
- Authority: The owner confirms F07 scope and GPT-6.1 Sol at `high` reasoning
  on 2026-10-08 and authorizes a separate stacked branch during F06 review.
  The owner approves the compatibility review update, fixup consolidation, and
  branch publication on 2026-10-09.
  The owner authorizes PR creation into `master` after F06 merges on 2026-10-09.
- Design: [DD15 and its ownership amendment](../design-decisions/15-clock-system.md#execution-clock-ownership-amendment--owner-approved-2026-10-07),
  [DD14](../design-decisions/14-real-time-replay-scheduler.md), and
  [Plan 003-F07](../plans/003-clean-slate-implementation.md#003-f07--wall-clock-platform-and-execution-clock-composition-conformance).
- Review base: `master` at `f20e139`, including merged F06; the F07 branch is
  `003-f07-clock-conformance` in `/private/tmp/diorama-f07`.

## Delivered boundary

F07 completes the wall/Core execution-clock milestone through public product
APIs. It adds seven tests, a multi-wall canonical golden, a compiled usage
example, and a [usage guide](../date-usage.md). No production implementation,
wall schema, playback policy, third-party dependency, unsafe concurrency
annotation, warning exception, or deployment floor changes.

The clock test target depends on the existing separately compiled consumer
test-support module. Its synthetic timed services expose the public
`SystemPreparationContext.clock` alongside time and scheduling. All F07 tests
import product modules normally; none uses `@testable` or private storage.

| Required behavior | New evidence |
| --- | --- |
| Several independent persisted walls plus one execution clock | The composition golden contains authored `+11:00`, pre-epoch `-08:00`, summer `-07:00`, repeated/backward millisecond values, and an empty wall. Public replay checks absolute dates, complete consumption, and byte-identical canonical writing. |
| Mixed record/replay/passthrough | File re-recording returns native fresh dates, preserves authored origin and positional delta, derives the later fresh delta, and retains replay/passthrough content. A second offline replay consumes all walls with no live factory activation. |
| Execution time without persisted clock content | A no-system run uses an empty scenario document without registration or publication. A declared unused wall records the existing empty golden while execution-clock sleeps create no observations. |
| Concurrent calls | Thirty-two callers record and replay one wall's serialized sequence while also using copied execution clocks. Assertions compare complete value sets, source counts, and consumption without assigning values to racing tasks. |
| Application timeouts alongside timed systems | A claimed synthetic traversal delivers a batch and a response through the shared clock. A structured application race exercises response success and timeout. Backward passthrough wall dates leave monotonic progress independent. |
| Cancellation and quiescence | An admitted clock sleep cancels at finish. A gated claimed system delivery completes and acknowledges before report freezing. Finish waits for it in all three wall modes, then both application and system clock handles return the same frozen horizon. Escaped wall reads never activate a live source. |

The timeout case deliberately leaves its replay claim incompletely consumed.
Canceling a clock sleep or timing out application work does not manufacture
system acknowledgement. The finalization report retains that verification fact
without making Diorama decide whether the test passes.

The quiescence case uses MainActor isolation to establish that the pending sleep
has entered suspension before finish. Gates establish claimed-delivery entry
and release; no sleep duration guesses whether shutdown is waiting. The scheduler
joins delivery and sleep handoffs, not arbitrary resumed application tasks.

## Existing evidence retained for the complete milestone

The complete platform jobs also run earlier conformance tests; F07 avoids
copying their implementation-level assertions:

- [F01 scalar goldens](003-F01-stable-time-scalars.md): signed/overflowing
  durations, independently rounded dates, fixed-offset limits, Foundation
  parsing/formatting, canonical milliseconds, and daylight-saving offsets.
- [F02 wall models and schemas](003-F02-empty-and-nonempty-wall-recordings.md):
  empty/nonempty validation, canonical payloads, malformed input, and cumulative
  arithmetic rejection.
- [F03 live sources](003-F03-wall-source-recording-and-passthrough.md): native
  forwarding, serialization, first-observation timezone selection, independent
  attachments, conversion failure, and closed-source ownership.
- [F04 replay](003-F04-sequential-wall-replay-and-exhaustion.md): sequential
  consumption, exhaustion continuation, unused records, and zero live access.
- [F05 merging](003-F05-clock-override-normalization-and-merge.md): positional
  override normalization, surviving and dropped positions, empty replacements,
  whole-candidate rejection, and preservation of the previous file.
- [F06 execution clocks](003-F06-core-execution-clock.md): transferable logical
  instants, checked arithmetic, cancellation/claim races, tolerance, scheduler
  ordering, horizon freezing, scoped access, and source/scheduler release.

## Executable example

`DioramaClockUsage` accepts a standard generic Swift `Clock` in application code.
It records wall observations around a retry delay to a temporary JSON document,
then replays identical dates without extra live reads or file writes. Its wall
source moves backward five seconds while execution time moves forward. A second
run uses only the execution clock and verifies an attachment-free definition
and empty usage. The example cleans up its temporary directory.

The canonical `scripts/test` now builds and runs both clock and random
executables on macOS and Linux. This is a command-line example; iOS verification
uses the library tests. The usage guide documents publication eligibility,
empty versus missing walls, mixed modes, positional editing, and timeout
ownership with links to their compiled evidence.

## Initial implementation verification

Focused public conformance: `swift test -Xswiftc -warnings-as-errors --filter
'ClockPersistenceConformanceTests|ClockSchedulingConformanceTests'` passes all
seven tests, including two timeout cases and three wall-mode shutdown cases.

| Gate | Result |
| --- | --- |
| `scripts/check` | Pass: formatting, strict lint, 374 host tests, warning-free debug/release builds, and both release examples. |
| `scripts/coverage swiftpm macos` | Pass: 374 tests, release builds/examples, and retained LCOV. |
| `scripts/coverage ios` | Pass: 373 applicable tests, release build, and retained LCOV on iPhone 17 / iOS 27.0. |
| Pinned Linux `scripts/coverage swiftpm linux` | Pass: 374 tests, debug/release builds, both release examples, and LCOV export. |
| Targeted iOS 18 runtime clock tests | Pass: six scalar tests and 45 wall/composition tests on iPhone 16 / iOS 18.0 (`22A3351`). |

Apple verification uses Xcode 27.0 (`27A266a`), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), and macOS 27.0.1 (`26A434`).
The canonical simulator is iPhone 17 / iOS 27.0 (`24A434`) with the iOS 18
compile-time deployment floor. The macOS deployment floor is 15.

Linux uses the policy's Apple Container profile, read-only source mount,
`x86_64`, two CPUs, 4 GB, and exact Swift image
`swift@sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9`.
The canonical command copies Package.swift, Sources, Tests, scripts, and Examples
into `/work`, then invokes `scripts/coverage swiftpm linux`.

The additional minimum-runtime command creates a task-owned simulator and runs
only the scalar and clock test targets, reusing the current simulator's derived
data after its coverage export:

```sh
F07_IOS18_DEVICE_ID=$(xcrun simctl create 'Diorama F07 iOS 18' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-16 \
  com.apple.CoreSimulator.SimRuntime.iOS-18-0)
xcodebuild test -scheme Diorama-Package \
  -destination "platform=iOS Simulator,id=$F07_IOS18_DEVICE_ID" \
  -derivedDataPath .build/ios-derived-data -parallel-testing-enabled NO \
  -only-testing:DioramaClockTests \
  -only-testing:DioramaCoreTests/StableTimeCodecTests \
  -enableCodeCoverage NO -resultBundlePath .build/ios18-clock-tests.xcresult \
  IPHONEOS_DEPLOYMENT_TARGET=18.0 SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
xcrun simctl delete "$F07_IOS18_DEVICE_ID"
```

This proves the selected Foundation scalar goldens, wall conversion/replay,
persistence, and clock composition on the actual minimum iOS simulator runtime.
It is a focused 51-test run; the full package matrix runs on iOS 27.0. The
minimum-runtime run disables coverage collection after canonical LCOV export,
so it does not replace current-runtime coverage.

Local macOS and iOS LCOV each report 4,708 of 4,799 product lines (98.10%). Linux
LCOV is exported in the ephemeral policy container and is not retained after
`--rm`. Verification logs are `/private/tmp/diorama-f07-{focused,check,macos,ios,linux,ios18}.log`.
The Apple `.xcresult` bundles and LCOV remain in the F07 worktree's `.build`.
Xcode retains its existing no-AppIntents metadata notice, and emulated Linux
retains the previously observed safeExec signal 32/33 notices. No compiler or
linter warning exception is added. Changed local documentation links and
anchors and `git diff --check` pass across the complete proposed diff.

F07 changes no production executable lines. Patch coverage therefore has no
new product-line denominator; platform coverage remains required and is
collected across the existing implementation. Hosted CI and Codecov evidence
use the separately authorized PR workflow.

## Limitations and review boundary

Wall observations have millisecond persisted precision. Recording selects
`TimeZone.current` at activation and stores a representable numeric offset at
the first observation; there is no setup encoding-zone option or regional rule
persistence. Calendar parsing and normalization remain Foundation-owned within
the accepted scalar contract. Wall overrides remain positional. Concurrent wall
reads do not preserve assignment to individual racing tasks.

Execution deadlines retain one-to-one real-time scheduling. There is no virtual
time, playback acceleration, deterministic application resumption order, or
implicit timeout cancellation of a domain interaction. Native HTTP and location
adapters are outside this milestone; synthetic batches and responses prove the
public extension boundary without advertising those later integrations.

Current Apple runtime runs do not establish macOS 15 runtime behavior. Simulator
verification does not establish physical-device behavior. The targeted iOS 18.0
check proves the clock milestone's selected runtime behavior separately from
compilation and the full current-runtime coverage job.

## Execution-context compatibility update — 2026-10-08

F06 review replaces its two scoped body forms with one context-first `execute`
API. F07 is restacked onto that revision. The approved review update migrates
the persistence/composition tests to `context.clock`, the direct Core lookups
to `execution.context.clock`, and the compiled example and guide to the same
consumer interface. No conformance behavior or persisted fixture changes.

The updated stack passes macOS `scripts/check`: strict formatting/lint,
374 tests, warning-as-error debug/release builds, and both release examples.
The F06 context revision separately passes its complete macOS, iOS Simulator,
and pinned Linux gates, as recorded in its
[review evidence](003-F06-core-execution-clock.md#execution-context-review-update--2026-10-08).
F07's broader coverage and minimum-runtime results above describe its initial
pre-context revision; they are not rerun for this compatibility update.
The owner approves consolidating the review fixups into their original test,
example, and evidence commits and pushing F07 on 2026-10-09.

The actual review commits are:

1. `003-F07: test(clock): verify persisted and timed clock composition`: public
   persistence/scheduling tests, canonical fixture, and existing test-support
   clock exposure with its test-only dependency edge.
2. `003-F07: docs(examples): demonstrate wall and execution clock usage`: compiled
   example, canonical execution, and usage/schema documentation.
3. `003-F07: docs(evidence): record clock conformance verification`: this
   evidence, documentation index, and owning plan completion status.

The owner's 2026-10-09 requests authorize fixup consolidation, branch
publication, and PR creation into `master` after F06 merges. Passing required
hosted checks and a separate explicit owner request gate merge. The next plan
item requires its own owner request.
