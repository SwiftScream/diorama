# 003-G06: Location origin policy and re-record replacement

- Date: 2026-10-30
- Status: Complete; owner review is complete and PR creation is authorized on 2026-10-31.
- Authority: The owner confirms the G06 scope, requests implementation, and authorizes PR creation after review.
- Plan: [003-G06](../plans/003-clean-slate-implementation.md#003-g06--location-origin-policy-and-re-record-replacement).
- Review base: `master` at `829d663`, including the coordinate type renames.
- Branch: `feat/003-g06-location-origin-merge`.
- Decisions: [DD09](../design-decisions/09-normalization-and-redaction.md),
  [DD16](../design-decisions/16-location-system.md), including their normalized
  record-delivery and baseline-isolation amendments.

## Delivered behavior

`LocationOriginPolicy` selects current setup coordinate, independent altitude,
and timestamp defaults without reading baseline content. Offsets and signed
latencies derive from fresh normalized observed origins first. The policy then
substitutes defaults, retaining fresh format, offsets, latencies, and other
content. Its complete-record preparation validates the result before admission
or consumer materialization. Incremental capture can use the same individual
origin selectors. Invalid default retiming throws a safe structural error.
Defaults are ordinary observations and are re-evaluated for each recording.
An absent location, altitude, or session timestamp never acquires an origin.

`LocationTracks.sessionDefinition` installs the system-owned finalization merge
on the existing typed sessions/header track. Core supplies validated baseline
and frozen fresh tracks after capture quiesces. Access has no retained override
fields and uses ordinary whole-track replacement.

The merge retains an authored baseline coordinate origin and independently
retains each authored altitude component, only when fresh measurements still
use it. Session timestamp overrides survive at the same numeric session position
only when the fresh session contains locations. Additional sessions use fresh
origins; removed and newly empty sessions lose obsolete overrides. This is
positional correspondence, with no event or call-site matching.

All other content comes from the fresh recording, including the coordinate
format, initial snapshot, session events, signed latencies, delays, access state,
notifications, and request barriers. Merged sessions validate timestamp arithmetic
and portable date ranges. Shared whole-record spatial validation checks effective
origins against fresh coordinate/altitude offsets before rebuilding a prepared
track. An invalid merge makes the candidate unhealthy, produces a safe
`recordingMergeFailed` fact, and prevents publication.

Fresh record-mode materialization sees current setup defaults and never retained
baseline overrides. Publication can therefore relocate or retime later replay
without changing already delivered values. No original-origin history or unused
observed value accompanies an effective override. No schema version changes.

## Proving tests

`LocationOriginPolicyTests` covers both meter and degree formats, unchanged fresh
offsets and latencies, normalized relocated/retimed materialization, all four
altitude-authorship combinations, independent partial defaults, changed/removed
defaults, invalid finite-value inputs, and invalid retiming before admission.
It also covers added/removed/empty sessions, initial-only and access-only content,
lost altitude, changed format, and wholesale replacement of manual non-origin
edits. The old baseline remains immutable.

`LocationOriginPublicationTests` uses a controlled `SystemDefinition` over actual
Core leases and the production session definition/merge. No native manager or
future facade is required. Tests exercise `Diorama` file loading, typed admission,
finalization, candidate validation, atomic publication, and subsequent replay:

- Authored origins beat current setup defaults while fresh record-mode output
  remains unchanged by finalization. Replay materializes the authored origins.
- The [canonical fixture](../../Tests/DioramaLocationTests/Fixtures/origin-rerecorded.json)
  fixes effective override-only bytes. Encoding and decoding are deterministic.
  Raw coordinate, altitude, and session-reference markers are absent from the
  candidate file and rendered diagnostics. No resource or sidecar file is created.
- Initial-only and access-only replacement drop obsolete session origins and
  publish healthy definitions. Access uses fresh whole-track content.
- First capture, changed defaults, and removed defaults publish ordinary origins
  across three sequential file-backed recordings, without sticky authorship.
- Two keyed attachments preserve independent baselines and current defaults.
- Individually valid baseline/fresh sessions combine into an out-of-range
  timestamp. Finalization refuses publication, retains only safe diagnostics,
  and leaves the previous file byte-identical.

The test target adds only the existing first-party `Diorama` product to exercise
real consumer publication. Production dependencies, public APIs, concurrency
annotations, deployment floors, and existing fixtures remain unchanged.

## Verification

| Gate | Result |
| --- | --- |
| Focused `swift test -Xswiftc -warnings-as-errors --filter 'LocationOrigin'` | All 12 tests pass, including parameterized formats, altitude authorship, and replacement shapes. |
| `scripts/check` | Pinned formatting and strict lint, all 578 host tests, public authoring/lifecycle compiler probes, warning-as-error Debug/Release builds, and release examples pass. |
| `scripts/coverage swiftpm macos` | All 578 tests and subordinate release/example gates pass; macOS LCOV exports. Both new source files have 100% executable-line coverage: 77 of 77 lines. |
| `scripts/verify-apple-toolchain` | Selected Xcode, Swift, SDK, and Simulator runtime checks pass. |
| `scripts/coverage ios` | Release compilation succeeds with the iOS 18 deployment floor. Simulator test startup stalls before results; the run is interrupted and its Simulator shuts down. No completed iOS test or coverage result is claimed. |
| Pinned Linux reproduction | The canonical x86_64, two-CPU, 4 GB container begins compilation. The run is interrupted during diagnosis of concurrent platform runs; it returns 137 after the explicit container stop. No Linux test or coverage pass is claimed. |
| Documentation and diff checks | Local documentation link targets resolve and `git diff --check` passes. |

Apple verification uses Xcode 27.0 (`27A266a`), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), and macOS 27.2 (`26B123`).
The attempted iOS profile is iPhone 17 / iOS 27.0 (`24A434`). It does not
establish execution on either that runtime or the minimum iOS runtime.
The Linux image is
`swift@sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9`,
with a read-only repository mount and package inputs copied into `/work`.

The focused and macOS coverage runs precede the rebase from `86d57e1` onto
the tool-maintenance baseline. G06's source and tests remain byte-identical
across that rebase; the canonical host gate runs again with the updated
SwiftFormat 0.64.4 pin. An initial attempt of that quality check times out in
four unchanged files while platform runs are active; the subsequent isolated
canonical run passes. No warning exception or check weakening is introduced.
Required PR checks enforce the full macOS, iOS, Linux, and Codecov matrix for
the revision being integrated.

## Commit breakdown

1. `003-G06: ref(location): share complete spatial validation` extracts the
   existing whole-record spatial validator without changing behavior.
2. `003-G06: feat(location): prepare and merge recording origins` adds the
   internal policy and typed finalization merge, proving tests, canonical fixture,
   and first-party consumer dependency in the test target.
3. `003-G06: docs(evidence): record location origin merge verification` records
   this evidence, schema behavior, documentation-index link, and owning plan status.

## Review boundary

G06 provides the internal preparation and merge boundary. G07 owns the public
manager/delegate facade; G08 owns live origin acquisition, incremental adapter
integration, native forwarding, and cleanup evidence. This unit does not implement
either adapter slice or change the existing incremental capture lifecycle.

Origin relocation does not remove route shape, timing, or other contextual
information. Positional session correspondence can retain a timestamp override
at a changed call site; no heuristic rematching is promised. Authored edits do
not regenerate recordings in other systems.

The owner completes G06 review and authorizes remote publication and PR creation
on 2026-10-31, then moves on to G07 review. Merge requires passing required CI
and a separate explicit owner request.
