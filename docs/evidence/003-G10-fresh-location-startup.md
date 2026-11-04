# 003-G10 — Fresh Location consumer startup

- Date: 2026-11-04
- Scope approved by the owner after the Location console example exposes a
  failure before native activation.

## Cause and correction

`Diorama` constructs a recordless setup layout and resolves a missing file to
that layout. Location previously validated it as a complete recording, requiring
an initial access segment that setup deliberately removes. Startup therefore
reports validation failure on the sessions track before constructing a driver.
Earlier native bridge tests start directly through Core with the declaration's
initial access record intact. Origin publication tests use a separate synthetic
definition or an existing baseline, so neither exercises this fresh consumer path.

Location validation now accepts only the exact record-mode empty layout: both
tracks have no records and the sessions header has no coordinate origin,
altitude origins, or initial snapshot. Existing native activation captures the
initial access segment and native access header before returning the manager.
Replay and nonempty content still require complete recording validation.
Persistence decoding and the version-one schema are unchanged.

## Regression evidence

The new consumer recording test fails before the production change in both
in-memory and missing-file cases, reproducing the reported startup failure.
With the correction, the native bridge suite passes all 18 tests, including:

- Fresh recording through `Diorama` with a controlled native driver, followed
  by in-memory or file replay with equivalent normalized coordinates and time.
- Successful file publication, unchanged bytes after replay, complete replay
  claims and consumption, no diagnostics, and no new native connection on replay.
- Rejection of a recordless replay layout and sessions missing their initial
  access segment in both record and replay, before driver construction.

The controlled driver avoids relying on permission prompts or nondeterministic
GPS for correctness. Live permission and callback delivery in the console example
remain a separate manual check.

## Verification

- `swift test --filter LocationNativeBridgeTests`: 18 tests pass after the fix;
  the pre-fix run fails the two fresh consumer recording cases.
- `scripts/check`: passes formatting, strict lint, all 610 host tests, coverage
  tooling fixtures, public authoring/lifecycle compiler probes, warning-free
  release builds, and both existing runnable command-line examples.
- `git diff --check`: passes.

This review uses local macOS verification. It makes no new local iOS or Linux
verification claim. The branch is stacked on `example/location-recording`; the
production review diff is against that branch and leaves its example fixups intact.
