# 003-E04: Strict grouped lifecycle accumulation

- Date: 2026-09-29
- Updated: 2026-10-04 after restacking above merged F02.
- Status: Implementation and macOS verification on the restacked branch complete;
  iOS and Linux verification of this revision remain CI gates. Owner review is
  the next checkpoint.
- Authority: The owner confirmed E04's documented scope and GPT-6 Sol, `high`
  model choice, then authorized implementation and a remote review branch.
- Review base: `master` at merged F02 commit `0dfb4a4`.
- Prerequisites: [E01 evidence](003-E01-logical-time-capture.md),
  [B04 evidence](003-B04-atomic-sequential-operations.md),
  [B08 evidence](003-B08-concurrent-finalization-and-evaluation.md),
  [DD03](../design-decisions/03-recorded-behaviors.md),
  [DD06](../design-decisions/06-runtime-to-snapshot-conversion.md), and
  [DD10](../design-decisions/10-lifecycle-and-ownership.md).

## Public contract

`SequentialTrackLease` begins a typed interaction or subscription and reserves
one sequential record before capturing its input. Each returned accumulator
owns later observations for that record. An interaction correlates each phase
with at most one decision and ends as returned, failed, or explicitly open at
the recording horizon. A subscription retains delivered values and nonterminal
dependency errors in order, then ends as finished, failed, or explicitly open.
Caller cancellation is not recorded as a lifecycle event by default.

Fields enter the accumulator as `PreparedValue` values at their observation
boundary. The caller captures `ExecutionTime` before conversion; the group
stores only nonnegative relative `Duration` offsets. Reservation occurs before
each field closure, so a slow conversion does not reorder observations. Group
construction validates timing and phase order. The complete group then passes
through the track's semantic validation policy exactly once at finalization;
capture transformations are not repeated.

The [grouped lifecycle recording guide](../grouped-lifecycle-recording.md)
documents the public API and examples. E04 adds in-memory semantic models only:
it does not add a persistence schema, selector, scheduler delivery path, or
native adapter.

## Ownership and failure argument

The owning lease holds a reserved slot until its group freezes. Finalization
closes admission before visiting slots and serializes competing closes. It
freezes groups and calls validation outside the lease state lock, so policy
callbacks and diagnostic sinks may reenter safely. A group detaches its stable
content and execution-time reference when frozen. Escaped handles cannot retain
the completed execution through that reference or alter its frozen result.

Within a group, a mutex serializes each reservation and terminal claim. A
single terminal slot prevents competing returned/failed or finished/failed
conclusions. A second conclusion, decision on an unknown phase, duplicate
decision, observation after a conclusion, or invalid timing is rejected with a
safe diagnostic and invalidates the recording candidate. Incomplete field
conversion, capture failure, and failed complete validation also suppress the
whole candidate. Calls after the horizon enter the separate late-diagnostic
log and cannot reopen the candidate. An otherwise active group freezes to an
explicit open conclusion.

## Proving tests

- Overlapping interactions preserve track reservation order while correlated
  phases, decisions, and terminal outcomes interleave.
- A nested input capture and a slow subscription field conversion prove
  reservation precedes conversion and keeps order.
- Subscription nonterminal errors permit later values; terminal failure and
  open-at-horizon remain distinct.
- Duplicate and foreign phase decisions, duplicate conclusions, post-terminal
  events, foreign-execution captures, and post-horizon calls reject safely.
- Each interaction and subscription field capture failure suppresses the
  candidate; unfinished conversion at the horizon does the same.
- Complete-group semantic validation runs once without repeating capture
  transforms. Public consumer-module use compiles without `@testable`.
- Immutable constructors reject negative or conflicting event timing, and
  escaped group handles release execution-owned resources after finish.

## Verification results

| Gate | Result |
| --- | --- |
| Focused E04 core and public consumer suites | 15 core tests across three suites and one consumer test pass; field-failure tests also exercise seven parameterized capture points. |
| F02 stack integration | The focused E04 core and public consumer suites pass after the typed track-header integration. The completed E06 stack passes `scripts/check`. |
| `scripts/check` | Pinned formatting and strict lint pass with zero violations; all 249 host tests, debug and release builds, and example execution pass. |
| `scripts/coverage swiftpm macos` | All 249 tests and release builds pass; LCOV exported. |
| `scripts/coverage ios` | All 249 tests passed on iPhone 17 / iOS 27.0 Simulator with the iOS 18 deployment target before the E03 phase-name fixups; CI will check this restacked revision. |
| Pinned Linux container reproduction | All 249 tests, release builds, and example execution passed before the E03 phase-name fixups; CI will check this restacked revision. |
| Local executable patch coverage against E03 | macOS covers 576 of 601 changed executable source lines (95.84%), above the 90% patch target. The earlier iOS run had the same result. |
| Documentation and branch diff | All 155 local links in the original E03/E04 documents resolve; the restacked E04 diff against merged F02 passes `git diff --check`. |

Apple verification uses Xcode 27.0 (`27A266a`) and Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`). Linux uses the canonical
[Apple Container reproduction](../quality-gates-and-ci.md#local-entry-points),
image `swift@sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9`,
`x86_64`, two CPUs, and 4 GB memory. It reports Swift 6.4
(`swift-6.4-RELEASE`) on Ubuntu 24.04. Repository sources are mounted read-only
and copied into the container's working directory.

The original patch coverage counts the LCOV `DA` lines in executable source
lines added or changed against E03. Compiler and linter warnings remain errors. Xcode's
metadata-extraction notice for test bundles without App Intents and the Linux
example launcher's `safeExec` signal 32/33 warnings do not affect the successful
test, build, or coverage results. Hosted CI and Codecov are PR merge gates;
local LCOV comparison makes no hosted-status claim.

## Review boundary and limitations

The review contains one feature commit for the shared grouped invariant,
both typed accumulators, lease integration, diagnostics, tests, and the public
contract, followed by this evidence and plan-status commit. The interaction
and subscription paths share record reservation, freeze, and candidate-health
rules, so the capability is reviewed as one unit. It introduces no third-party
dependency, persisted format,
native value storage, unsafe concurrency annotation, or deployment-floor
change. A consumer must still return from its synchronous or asynchronous
delivery scope for E03 shutdown quiescence; E04's accumulator does not provide
a finalization timeout. Replay selection of whole groups belongs to E05, and
capability-specific event delivery remains in later units. iOS verification
uses the installed simulator runtime with an iOS 18 compile-time floor.
