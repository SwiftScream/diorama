# 003-H08 — Validate ordinary interaction construction

- Status: Complete; the owner approves PR creation on 2026-11-20.
- Date: 2026-11-20.
- Base: Merged H09 commit `0130b70`.
- Scope: The owner requests extracting H10's correction to ordinary interaction
  construction into a separate preparatory fix commit.

## Corrected boundary

H08 checks the effective request method when selecting derived response lengths
and when encoding/decoding interactions, but its nonthrowing public interaction
initializer permits incompatible in-memory combinations. A response derived using
GET can be attached to a HEAD/CONNECT request and remain invalid until encoding.

`HTTPInteraction.init(initialRequest:result:)` now throws and rejects that
combination immediately. Decoding delegates to the initializer; duplicate codec
checks are removed because the complete runtime interaction is immutable. Literal
response lengths, ordinary GET/POST derived responses, pre-response failures, and
open attempts remain valid. The existing URLSession failure composition test
adopts `try` at its two construction sites.

This commit includes no redirects, recursive traversal, native bridge changes,
dependencies, or persistence-shape changes. H10 separately extends validation to
each redirect edge's effective request method and adds contextual decoding paths.

## Verification

Regression tests reject incompatible derived responses during ordinary
construction without encoding, preserve compatible and literal cases, and reject
edited persisted HEAD/CONNECT requests through the same construction boundary.

With repository-selected Xcode 27.2 / Swift 6.4.2 on macOS:

- Focused Content-Length, lifecycle, and URLSession failure coding suites pass
  with warnings treated as errors (28 reported tests).
- `scripts/check` passes strict format/lint, all nine host test products,
  coverage-export fixtures, public authoring/lifecycle compiler probes, release
  builds, and Random/Date usage examples.
- `git diff --check` passes.

The sandboxed focused run cannot write compiler caches; passing checks use
approved normal cache access. Initial lint catches two overlong regression-test
lines, corrected without changing lint policy. No new local iOS/Linux or coverage
collection is claimed. The PR retains hosted platform and coverage evidence.
Merge requires passing required checks and a separate explicit owner request.

## Review boundary

`003-H08: fix(http): validate interaction construction` contains the throwing
constructor, removal of redundant codec checks, two existing caller migrations,
focused regressions, contract/index documentation, and owning-plan evidence.
Review it independently against `0130b70`; H10 is restacked above this fix and
retains the recursive redirect-specific validation.
