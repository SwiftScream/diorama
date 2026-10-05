# 003-F03: Wall-source recording and passthrough

- Date: 2026-10-05
- Status: Complete; the owner approves squashing the review fixups and
  authorizes PR creation on 2026-10-07.
- Authority: The owner's confirmation of 003-F03 scope and its documented
  GPT-6 Sol at `high` reasoning on 2026-10-05;
  [Decisions 6](../design-decisions/06-runtime-to-snapshot-conversion.md),
  [9](../design-decisions/09-normalization-and-redaction.md), and
  [15](../design-decisions/15-clock-system.md); and the
  [approved plan](../plans/003-clean-slate-implementation.md#003-f03--wall-source-recording-and-passthrough).
- Review base: `master` at `d158515`, after 003-F02.

## Delivered boundary

`DioramaClockSystem.instance` now creates a reusable named wall attachment. Its
consumer dependency and injected source conform to the small synchronous,
nonthrowing `DioramaWallClock` protocol returning `Date`. A default source reads
the platform wall clock; an injected `Sendable` source factory runs once per
execution after successful preparation. Multiple named attachments
own independent sources and wall tracks.

Record mode reserves a track position before reading the source. One lock keeps
each source read, conversion, and append in source order. It returns the native
`Date` even though the track stores an independently rounded millisecond value.
The first observation sets the origin header to the selected timezone's numeric
offset at that native instant. Record activation captures `TimeZone.current`;
`instance` has no timezone parameter. Recording state owns timezone selection,
rounding, and cumulative validation; passthrough has no recording state or zone.
Later daylight-saving changes do not rewrite the origin offset. The track
derives signed deltas between consecutive rounded absolute values without recording read timing or regional timezone rules.

An empty record run writes an empty wall track, including when replacing a
nonempty baseline. An unrepresentable observation or offset reports a safe
conversion diagnostic, preserves the native live return, and makes the entire
recording candidate unhealthy. Subminute historical timezone offsets cannot be
represented by this schema and follow that failure path. A read racing finish
retains a pending track position until it either admits or is reported
incomplete. Passthrough reads the source and returns its native value without
changing a loaded track. Finish releases the source; an escaped handle retains
only its last returned value and reports closed use.

This unit does not add wall replay, scheduler sleeps, automatic clock
attachment, or third-party dependencies. The owner-approved 2026-10-06
[timezone refinement](../design-decisions/15-clock-system.md#recording-timezone-refinement--owner-approved-2026-10-06)
clears an ordinary baseline offset on re-record. F05 still owns merging an
authored whole-origin override, including its offset, into the fresh recording;
this unit does not implement that merge or independent offset overrides.
Replay consumption and its diagnostic continuation belong to 003-F04.

## Verification

The timezone review fixup reruns every gate below on 2026-10-06. The focused
command `swift test -Xswiftc -warnings-as-errors --filter DioramaClockTests`
passes all 19 clock tests; each full platform suite passes 287 tests. The Linux
example launcher emits the previously recorded nonfatal SwiftPM `safeExec`
signal 32/33 warnings, then completes successfully. Compiler and lint checks
remain warning-free.

| Gate | Local result |
| --- | --- |
| Focused wall-source suite | Eleven tests pass (including two empty-replacement cases) for native returns, independent absolute rounding, DST, fresh offset replacement, empty observed/overridden replacement, passthrough preservation, keyed sources, fresh factories, concurrent order, safe date/offset conversion failure, and finish release. |
| Canonical `scripts/check` | Passes SwiftFormat, strict SwiftLint, warning-free debug and release builds, host tests, and the example. |
| macOS coverage | `scripts/coverage swiftpm macos` passes tests and release builds and exports LCOV. |
| iOS Simulator coverage | `scripts/coverage ios` passes Release build, tests on iPhone 17 / iOS 27.0 with the iOS 18 deployment floor, and LCOV export. |
| Linux coverage | The pinned Swift 6.4 x86_64 Apple Container command passes tests, release builds, the example, and LCOV export. |

Apple verification uses Xcode 27.0 (`27A266a`) and Apple Swift 6.4. The iOS
result proves behavior on the installed iOS 27 simulator and compile-time
availability at iOS 18, not runtime behavior on an iOS 18 installation. The
required PR matrix remains the integration gate for the revision merged.

## Review boundary

The behavior commit contains the wall protocol, live attachment, source
ownership, recording validation, and focused tests, including the approved
timezone refinement. A separate documentation commit records this evidence
and the owning plan's completed status. The owner approves squashing the two
review fixups into those commits and authorizes PR creation on 2026-10-07.
Squashing preserves the verified implementation and test contents. The complete
feature-branch diff against `master` is the review surface. Merge requires
passing required CI and a separate explicit owner request.
