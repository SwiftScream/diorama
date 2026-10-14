# 003-Fa03: Whole-track Date admission

- Date: 2026-10-11
- Rebased onto merged Fa02 and reverified: 2026-10-14
- Status: Complete.
- Plan: [003-Fa03](../plans/003-clean-slate-implementation.md#003-fa03--whole-track-date-admission-and-preparation-proof)
- Authority: The owner-approved ordered Fa stack, current session model/settings,
  DD15/DD20, and the public validation boundary delivered by Fa02.

## Runtime admission

Date's definition now calls `context.validate(wall)` for record and replay.
The callback constructs the existing strict `WallRecording` from the resolved
header and complete ordered values. This is the same interpretation used by
Date's codec and recording merge; no competing validator, schema change,
normalization pass, or new public Date model is added. Passthrough returns before
track validation, preserving its native lifetime and prepared baseline.

Fa04's scalar policy already rejects nonfinite, out-of-range, and nonmillisecond
values. This hook closes the remaining whole-track gap: missing or invalid
headers, an origin on empty content, and consistency across effective values.
A no-op generic preparation policy cannot authorize malformed Date semantics.
All systems validate before any state/dependency factory runs, including when
an invalid Date attachment follows another configured system.

## Public proving cases

`WholeTrackAdmissionTests` uses ordinary Diorama, Core, Date, and persistence
imports. Generic `SequentialTrack` construction deliberately uses no-op header
and value preparation, then supplies the resulting baseline to normal Date setup.

| Input | Preparation result in record and replay |
| --- | --- |
| Nonfinite Date, offset 0 | Scalar validation failure with track/record context. |
| Finite Date, missing offset | Whole-track validation failure with track context. |
| Finite Date, offset 2000 minutes | Whole-track validation failure with track context. |
| Submillisecond Date, offset 0 | Scalar validation failure with track/record context. |
| Empty values with offset 0 | Whole-track validation failure with track context. |

Each case fails direct execution and the fixed-baseline facade. An earlier
public system records state/dependency construction attempts; all counts remain
zero. Valid reusable Date setup paired with malformed authoritative content
cannot fall back to its empty declaration.

A deliberately permissive public test codec returns malformed typed content as
`.loaded`. Both record and replay repository paths reject it at Date preparation,
retain the exact loaded evidence, invoke no source/body, and never publish.
This isolates runtime admission from decoder correctness. The real first-party
codec separately rejects malformed structures at encoding, and a malformed
numeric origin offset fails decoding and repository replay before activation.
The existing policy for unusable record-mode files remains unchanged.

Controls cover empty content, repeated/backward dates, authored origin and later
values, both fixed numeric Date bounds in one track, and offsets at both
±14-hour limits. Replay returns the original effective values and consumes the
records; record startup accepts the baseline without mutating it. Existing
mixed-mode re-record, override merge, scalar, and file tests remain intact.
Passthrough accepts the malformed programmatic controls without content policies,
continues live reads after finish, and adds no post-finish facts.

Fa02's external typed-declaration tests additionally prove read-only header and
whole-track inspection, validation-only admission, no repeated transformations
or claims on lookup, and validation before all activation. They remain part of
this unit's full gate.

## Earlier verification — 2026-10-13

The 2026-10-13 restack onto Fa02's final-report-only revision preserves the Date
implementation and public regression tests unchanged. Fresh focused admission
checks pass all five tests covering 28 invocations. `scripts/check` passes on
Apple Swift 6.4 / Xcode 27.0: 421 host tests, formatting, strict lint,
warnings-as-errors compilation, one positive and nine negative public compiler
probes, release builds, and both examples.

An isolated snapshot passes `scripts/coverage ios`: iOS 18 deployment-target
release compilation, 420 tests on iPhone 17 / iOS 27.0, and current-build LCOV
export. `scripts/coverage swiftpm linux` passes 421 tests, the public compiler
probes, release builds, both examples, and LCOV export using the approved pinned
Swift 6.4 Ubuntu x86_64 image, two CPUs, and 4 GB through Apple Container.
The existing emulation-launcher signal 32/33 notices remain; compiler warnings
still fail the gate.

Those platform results describe the 2026-10-13 revision, before Fa02's final
authoring API review. They are historical evidence, not verification of the
current rebased revision.

This unit closes R2 with runtime admission; it
does not rewrite F02's historical exclusion or change Fa04's fixed wall-date
range. Earlier test totals described the pre-Fa09 stack and are superseded by
the fresh local results above.

## Merged Fa02 compatibility — 2026-10-14

Rebase the two Fa03 commits onto merged Fa02 (`add26f3`). The Date validation
hook applies unchanged. Update the earlier-attachment test definition to use
Fa02's reviewed `SystemExecution` name; retain key-based track lookup and the
registered definition's policies from the base.

Focused whole-track admission and managed-definition/track-lookup checks pass
18 tests. `scripts/check` passes all 424 macOS tests, formatting, strict lint,
warnings-as-errors compilation, one positive and seven negative public compiler
probes, release builds, and both examples on Apple Swift 6.4 / Xcode 27.0.
`git diff --check` passes against master. Required PR checks cover the current
revision's macOS, iOS, Linux, and Codecov matrix.
