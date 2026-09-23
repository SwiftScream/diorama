# 003-C06: Publication failures and actionable reports

- Scope and model confirmed: 2026-09-22
- Model: GPT-5.6 Sol, `high` reasoning
- Status: Complete; implementation and local platform verification complete on 2026-09-22
- Owning unit: [003-C06](../plans/003-clean-slate-implementation.md#003-c06--publication-failures-and-actionable-reports)
- Governing decisions: [DD05–DD10](../design-decisions/README.md) and
  [DD18](../design-decisions/18-diorama-setup-and-scenario-data.md)

## Report contract

Every successful scoped `Diorama.execute` result can produce a safe
`DioramaReport` on demand from its finalization, load, and publication outcomes.
The report contains the scenario identity, prior-document evidence, four-way
disposition, preservation outcome, candidate counts, ordered earlier
diagnostics, and stage-specific issues. Its deterministic renderer includes
core finalization facts before publication facts. It never inspects the
definition's recorded values or renders an arbitrary underlying error.

Prior-document evidence distinguishes content observed at startup, known
absence, an unreadable unknown state, and in-memory execution.
`unchangedByThisRun` means this run made no commit; another concurrent writer
may still modify the configured storage. `committedByThisRun` includes both
creation and replacement. The report does not repeat the caller's destination
configuration or retain its storage.

The candidate summary counts configured attachments, tracks, newly admitted
records, and incomplete reservations. It marks an unhealthy candidate
unavailable; its counts describe the attempted run and do not expose partial
semantic output. `recordedCount` excludes preserved replay and passthrough
baseline values. A complete healthy definition remains on `DioramaResult`
after an encoding or precommit storage failure, separate from the safe report.

Recording issues carry safe attachment, track, or record context and a
diagnostic sequence. Conversion and preparation failures identify stages that
the current sequential system can exercise. Encoding and storage issues report
bounded, safe cause categories. For Diorama's file backend, staging, commit,
and cleanup failures retain their precise operation and POSIX or Cocoa code
without paths or native descriptions. Unknown custom backend errors use
`unspecified` in the safe report while their exact errors remain available in
`DioramaPublication`. Grouping and whole-candidate validation diagnostics wait
for systems that define those operations.

## Publication and preservation matrix

| Disposition | Definition | Storage effect from this run | Report evidence |
| --- | --- | --- | --- |
| Not requested | Complete when core is healthy | No write | Candidate summary. |
| Refused unhealthy | Unavailable | No write | Each invalidating diagnostic's stage and affected identity. |
| Failed before commit | Complete | No commit | Encoding or storage stage, bounded cause, prior-document state. |
| Published | Complete | One commit | Commit disposition; later cleanup failure remains a separate issue. |

A postcommit cleanup failure cannot undo the committed document. A precommit
stage or commit failure may have an additional staging-cleanup issue while the
prior file remains unchanged by this run. The report preserves earlier
diagnostics in either case. Body errors and cancellation retain DD18's scoped
rethrow contract; scoped execution completes core finalization and publication
before returning or rethrowing.

## Verification

Focused tests inject native storage faults at staging creation, partial write,
commit, and postcommit cleanup, including simultaneous commit and cleanup
failure. They check actual prior bytes, exact publication disposition, the
candidate retained after precommit failure, and a safe renderer golden suffix.
Other tests inject conversion and preparation validation failures into one of
two record tracks; one unhealthy track prevents all writes while a caught
conversion failure preserves the live body value.
A finalization sink test proves ledger retention before notification and
retention of an earlier fact after a cleanup failure. A canceled scoped caller
receives its completed report after one publication attempt. A lifetime test
proves the completed report does not retain repository storage. Arbitrary backend
error descriptions are never invoked by report rendering. The report is derived
when accessed, so an unused result does no report construction or rendering.

| Gate | Local result |
| --- | --- |
| Focused C06 tests | Pass, including report, finalization sink, and lifetime cases. |
| `scripts/check` | Pass on the current review revision: strict format and lint, all 195 macOS tests, release library and example builds. |
| `scripts/coverage swiftpm macos` | Pass on the initial revision: 195 tests and LCOV; 2,627/2,678 source lines (98.10%). |
| `scripts/coverage ios` | Pass on the initial revision: 195 tests on iPhone 17 / iOS 27 Simulator and LCOV; 2,627/2,678 source lines (98.10%). |
| Pinned Linux container running `scripts/coverage swiftpm linux` | Pass on the initial revision: 195 tests, release library and example builds, and LCOV export. |

On the initial revision, `DioramaReport.swift` has 190/196 executable lines
covered on macOS. The Linux run uses the policy's pinned x86_64 Swift 6.4 image, two CPUs,
4 GiB memory, and read-only source mount; its temporary LCOV output is not
retained on the host. Xcode emits the existing App Intents metadata-extraction
warnings for test bundles without an AppIntents dependency. Swift compiler
and SwiftLint checks pass with warnings treated as errors.

## Review boundary

This branch builds on the completed C05 baseline. A preparatory Core commit
shares report formatting and verifies finalization ordering. A Diorama commit
adds the publication report, integration tests, and this plan evidence.
No dependency, persistence schema, deployment floor, unsafe concurrency
annotation, or quality-gate exception is introduced. System-specific grouping
and normalization behavior remains with each system's later unit.
