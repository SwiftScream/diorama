# 003-F05: Clock override normalization and re-record merge

- Recorded: 2026-10-07
- Status: Complete. The owner authorizes PR creation into `master` on 2026-10-07.
- Authority: The owner confirms the outlined F05 scope and requests
  implementation with the recommended GPT-6.1 Sol at `high` reasoning.
- Plan: [F05](../plans/003-clean-slate-implementation.md#003-f05--clock-override-normalization-and-re-record-merge).
- Review base: `master` at `3fbd138`, including the F03A abandonment record.
- Branch: `003-f05-clock-override-merge`.
- Decisions: [DD03](../design-decisions/03-recorded-behaviors.md),
  [DD07](../design-decisions/07-persistence-boundary.md),
  [DD09](../design-decisions/09-normalization-and-redaction.md), and
  [DD15](../design-decisions/15-clock-system.md), including its
  [recording-timezone refinement](../design-decisions/15-clock-system.md#recording-timezone-refinement--owner-approved-2026-10-06).

## Delivered behavior

Wall re-recording preserves the baseline's authored whole-origin override,
including its absolute date and numeric UTC offset. Later authored deltas
survive only at positions that still exist. An ordinary origin and ordinary
deltas are replaced by fresh observations. Position zero remains canonical
observed `0ms`; the existing tolerant reader folds its override into an
authored origin before merging. An offset cannot be overridden independently.

Fresh dates are independently rounded and fresh successive deltas are derived
before any override is applied. For example, fresh offsets of 0s, 2s, and 9s
produce 2s and 7s deltas. Preserving a 5s override at position one yields
effective offsets of 0s, 5s, and 12s. The later fresh 7s delta is preserved;
it is not recalculated from the preceding overridden value.

Clock reconstructs both strict wall recordings, combines the origin and
positional deltas, cumulatively validates the complete result, and rebuilds
the prepared absolute-date track. Canonical writing retains only effective
override forms. The version-one payload and all existing reader forms stay
unchanged. Successfully returned live dates remain native, including their
submillisecond precision, independently of the merged candidate.

Overrides beyond the new sequence length are dropped. An empty replacement
drops all prior content, including an authored origin and offset. Those
deliberate deletions remain healthy and can publish. Invalid merged cumulative
deltas instead make the whole candidate unhealthy: no healthy definition is
returned, and the previous file remains unchanged.

## Public finalization boundary

`RecordingMerge<Value, Header>` is a typed, `@Sendable` callback receiving the
validated baseline and fresh prepared track. Systems optionally register it
with `SystemPreparationContext.lease(..., mergeRecording:)`, for either a
headerless or headered track. No persistence or record-conformance requirement
is added.

Normal record-mode finalization invokes it once after scheduler quiescence and
record freeze, outside lease state locks. Replay, passthrough, unhealthy capture,
and startup rollback do not invoke it. Without a callback, whole-track
replacement keeps its previous behavior. Typed inputs and outputs retain the
same value/header relationship; heterogeneous erasure stays at the existing
track replacement boundary.

The system owns correspondence and complete domain validation. Core checks
that the returned track identity is unchanged and validates its prepared
header and values using the setup policies, without rerunning capture
transformations. A thrown merge or wrong identity retains a safe
`recordingMergeFailed` diagnostic. Setup validation failures retain their
normal preparation diagnostics. Neither path renders values or arbitrary
error descriptions. Failure affects the whole candidate before in-memory
result delivery or file publication.

Closing the lease transfers policy and callback ownership out of the state
lock and releases it after processing, even when the callback is discarded.
Escaped leases retain neither the baseline nor callback captures. Usage counts
continue to describe fresh capture, independently of the merged representation.
The [record service guide](../record-services.md#recording-merge) documents
the public extension contract.

## Proving tests

Core coverage exercises typed baseline/fresh headers and values, empty fresh
content, exactly-once concurrent finish, callback and destructor reentry outside
state locks, policy release after unhealthy capture, rollback, non-recording
modes, changed identity, thrown merge, final header/value validation, and omitted
capture transforms. A suspended header capture proves merge is skipped while
late completion cannot change the frozen report. A later successful header
cannot erase an earlier failed attempt's recording-health fact.

A separately compiled consumer uses only public imports to merge non-`Codable`
values, retain its immutable baseline, and replay the resulting in-memory
definition. It proves the headerless overload as well as the first-party
headered Clock use.

Clock evidence includes:

- Re-recording an edited input fixture with position-zero and later overrides
  into the committed `clock-rerecorded-overrides.json` golden. Origin date/offset
  and override-only canonical output survive; the baseline bytes stay unchanged.
- Native submillisecond returns remain intact while the candidate uses fresh
  independent millisecond rounding, preserved overrides, and fresh later deltas.
- An ordinary origin uses the fresh offset chosen from `TimeZone.current`.
- File-backed shrinking and empty replacements publish healthy complete data;
  subsequent file replay avoids the source.
- Two individually valid sequences combine into overflowing cumulative deltas.
  The merge refuses whole publication and preserves the original file while
  all native live values still reach the body.
- Three separately keyed clocks in record/replay/passthrough modes keep their
  source, cursor, and baseline behavior independent.

The insertion/removal proof is deliberately positional. With a baseline
position-two 7s override:

| Fresh read offsets | Merged successive deltas | Result |
| --- | --- | --- |
| 0s, 0.5s, 1s, 2s, 3s | 0ms, 500ms, override 7s, 1s, 1s | Insertion does not rematch the override to a call site. |
| 0s, 2s, 3s | 0ms, 2s, override 7s | Removal keeps the override at position two. |
| 0s, 1s | 0ms, 1s | The vanished position-two override is dropped. |
| No reads | Empty payload | Every obsolete field is dropped. |

These results inform the post-review
[named checkpoint assessment](../checkpoint-design-notes.md#f05-evidence-and-placement-assessment--2026-10-07).
It recommends a successor-plan design unit for owner consideration. This unit
does not implement checkpoints or authorize their placement.

## Verification

| Gate | Result |
| --- | --- |
| Focused Core, consumer, and Clock merge suites | All 17 tests pass, including parameterized modes, failure paths, and positional edits. |
| `scripts/check` | Pinned formatting and strict lint, all 345 host tests, warning-as-error debug/release builds, and release example build/execution pass. |
| `scripts/coverage swiftpm macos` | All 345 tests and release/example gates pass; macOS LCOV exported. |
| `scripts/coverage ios` | Release build and all 345 tests pass on iPhone 17 / iOS 27.0 Simulator with the iOS 18 deployment floor; iOS LCOV exported. |
| Pinned Linux reproduction | All 345 tests, warning-as-error debug/release builds, release example build/execution, and Linux LCOV export pass. |
| `scripts/verify-apple-toolchain` | All Xcode, Swift, SDK, and Simulator runtime pins pass. |

The local macOS export covers 106 of 107 changed executable source lines
relative to `3fbd138`. The uncovered line discards a failed latest header's
merge policy; the tests prove unhealthy capture and a failed header followed
by a successful header both skip the callback. Hosted Codecov computes its
own patch metric from platform uploads.

Apple verification uses Xcode 27.0 (`27A266a`), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), and macOS 27.0.1 (`26A434`).
The Simulator profile uses iPhone 17 / iOS 27.0 (`24A434`), with the iOS 18
deployment floor. It does not establish execution on the minimum iOS runtime.

Linux uses the canonical Apple Container profile with a read-only repository
mount, `x86_64`, two CPUs, 4 GB memory, and
`swift@sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9`.
Package inputs are copied into `/work` for `scripts/coverage swiftpm linux`.
Its ephemeral LCOV is not retained locally after the canonical `--rm` run.

Xcode emits its existing metadata extraction notice for test bundles without
App Intents. The emulated Linux example emits the previously observed
`safeExec` signal 32/33 notices and exits successfully. Compiler and linter
warnings remain errors; no warning exception is added.

## Review boundary

1. `003-F05: feat(core): merge typed recordings at finalization`: the public
   typed hook, lifecycle/validation/health handling, Core and external consumer
   tests, and record-service guide.
2. `003-F05: feat(clock): preserve overrides during rerecording`: domain merge,
   shared prepared-track construction, canonical fixture, and real in-memory
   and file-backed integration tests. The Clock test target adds the existing
   first-party `Diorama` dependency to exercise actual scoped publication.
3. `003-F05: docs(evidence): record clock override merge verification`: this
   evidence, schema guide, owning plan status, and documentation index link.

Production dependency graphs, third-party dependencies, schema versions,
deployment floors, live capture/lifetime policy, replay fallback, and other
systems' merge policies stay unchanged. No unsafe concurrency annotation,
warning exception, native-capture abstraction, or generic matching framework
is introduced. Positional call-site drift is an accepted clock limitation.

The owner authorizes PR creation on 2026-10-07 after reviewing the Core
validation boundary, callback ownership, and clock representation. Hosted
required CI and Codecov evidence use that authorized PR workflow. Merge
requires passing required checks for the final revision and a separate
explicit owner request. Starting the next unit requires its own instruction.
