# 003-Ra3: Capture health before merge

- Date: 2026-10-15
- Status: Complete.
- Plan: [003-Ra3](../plans/003-clean-slate-implementation.md#003-ra3--establish-complete-capture-health-before-merging)
- Authority: Owner request to fix Ra3 on a separate branch and raise a PR;
  [DD21's state-owned lifecycle](../design-decisions/21-managed-native-lifecycle.md#state-owned-lifecycle--owner-approved-2026-10-15)
  and the [recording merge contract](../record-services.md#recording-merge).

## Finalization boundary

Capture health is scenario-wide. Normal finish drains admitted work and runs
cleanup, then closes every lease before invoking any recording merge. Lease
closure freezes accepted accumulators once, validates their prepared values,
retains usage, and detaches capture resources. Its result retains only the
stable recording inputs, typed merge/validation policy, and diagnostic reporter
needed for candidate construction.

Core then detaches State and releases its Dependencies and lifecycle captures
outside locks. Destruction can contribute final facts and invalidate capture.
Only after this phase does finish invoke recording finalizers in attachment
and track order, checking global health before each one. A later-track freeze
failure or required release-time invalidation therefore prevents every merge.
A merge failure prevents later merge callbacks and candidate publication.

Rollback closes leases and discards their finalizers. Replay and passthrough
do not merge. Merge validation still checks identity, headers, and prepared
values without repeating transformations. Usage continues to describe this
run's observations rather than merged content. Existing callbacks, public
signatures, and persistence schemas remain compatible.

## Regression evidence

`RecordingMergePhaseTests` imports public Core APIs and adds six tests covering
ten parameterized invocations:

- Two attachments, each with two tracks, freeze all four records and release
  all eight State, Dependency, and accumulator witnesses before ordered merges.
  Cleanup mutations reach the frozen records; repeated finish does not repeat
  freeze or merge, and usage retains the captured record counts.
- The last track returns an incomplete freeze or fails prepared-value
  validation. No earlier merge runs or adds a misleading merge-failure fact.
- State, Dependency, or accumulator destruction invalidates capture before
  any merge, with the fact retained in the final report and no late diagnostic.
- A throwing first merge prevents subsequent merges after complete capture
  and runtime release.
- Replay and passthrough never invoke merges.
- A later activation failure freezes earlier accepted records and releases
  their owners during rollback without invoking merges.

The first three tests fail against the original implementation, reproducing
interleaved freeze/merge and release after merge. Existing Core and Date suites
add concurrent finish, callback release, typed baseline/header transfer,
transformation counts, malformed merge results, authored Date overrides,
replacement publication, and baseline preservation evidence.

## Verification

On Apple Swift 6.4 / Xcode 27.0:

- Focused tests pass with warnings as errors using
  `swift test -Xswiftc -warnings-as-errors --filter 'RecordingMerge|WallOverrideMerge|StateLifecycleTests|RecordCaptureTests|ReplayContinuationLifetimeTests'`
  (43 tests). The same filter also passes all 43 tests in optimized Release
  with `swift test -c release -Xswiftc -warnings-as-errors`.
- `scripts/check` passes all 463 host tests, SwiftFormat, strict SwiftLint,
  public authoring and lifecycle compiler probes, Release builds, and both
  examples.
- V-doc checks cover local links, status consistency, the complete branch
  diff, and whitespace.

Required PR checks cover the current revision's macOS, iOS Simulator, Linux,
and Codecov matrix. This unit does not change scheduler cancellation ownership
or force release of references retained by application code or setup policies.
