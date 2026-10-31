# 003-G07: Preparatory replay-header read

- Date: 2026-11-01
- Status: Implementation and canonical host verification complete; ready for owner review.
- Authority: During G07 review, the owner approves a replay-header read and requests a separate preparatory commit.
- Branch: `feat/003-g07-location-manager`.
- Plan: [G07](../plans/003-clean-slate-implementation.md#003-g07--main-actor-managerdelegate-facade-over-location-replay).
- Contract: [Record services](../record-services.md), [DD19](../design-decisions/19-system-owned-records.md), and [DD21](../design-decisions/21-managed-native-lifecycle.md).

## Behavior and review boundary

`SequentialTrackLease.replayHeader()` returns its validated baseline header
without claiming or consuming records, rerunning preparation, or selecting a
record continuation. `SystemOperation.replayHeader(on:)` provides the same
read within managed state protection. Both support empty or exhausted replay
tracks and preserve optional and reference-valued header types.

Record-mode reads report and throw a wrong-mode failure. Admission closure
immediately rejects reads, even before finalization detaches track storage.
Header reads use the existing direct-read activity tracker, so finalization
joins admitted reads through diagnostic retention. Errors always throw;
record fallback and replay-last policies do not apply to header reads.
Closure releases the lease's header storage; returned values remain owned
by callers without extending lease admission. Late read diagnostics do not
change the immutable completed report.

The lease's selection and diagnostic helpers remain private in the same file
as its storage and operations. No mutable storage becomes accessible outside
the lease implementation. The public system-authoring compiler probe covers
both accessor forms through ordinary imports.

This Core API is a preparatory commit before G07's attachment-state refactor.
Location state and engines are unchanged; removing their separately supplied
headers is a subsequent review update. No persistence format, dependency,
platform floor, concurrency annotation, or accepted decision changes.

## Verification

- `swift test -Xswiftc -warnings-as-errors --filter ReplayHeaderTests`: all six tests pass.
- Review fixup: focused replay-header, track-header, and replay-selection suites
  pass all 19 tests after restoring the helpers' private visibility.
- `scripts/check`: pinned formatting and strict lint pass; all 588 host tests,
  coverage-export fixtures, public authoring/lifecycle compiler probes,
  warning-as-error Debug/Release compilation, and release examples pass.
- `git diff --check` and local documentation link checks pass.

Verification uses the locally selected Xcode 27.2 / Apple Swift 6.4.2 on
macOS 27.2 (`26B123`). It does not establish verification with the branch's
older pinned Xcode 27.0 / Swift 6.4 toolchain. No new iOS, Linux, or coverage
run is claimed; required PR checks remain the platform acceptance gate.

The focused tests prove unchanged claim/consumption ordering, validation and
transform counts, readable empty and optional headers, wrong-mode errors,
independence from record continuation, closure during a controlled stop hook,
immutable final reports, and reference-header release with a retained lease.

PR creation and merge retain G07's separate owner checkpoints.
