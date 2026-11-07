# 003-C08 — Passthrough without baseline recording

- Date: 2026-11-07
- Scope and rule amendment approved by the owner on 2026-11-07.
- Governing contract: [DD18's passthrough-without-baseline amendment](../design-decisions/18-diorama-setup-and-scenario-data.md#passthrough-without-baseline--owner-approved-2026-11-07),
  together with DD07's whole-document publication and DD20's baseline preservation.

## Problem and correction

Consumer startup reconciles configured system declarations with an optional
baseline. Before this correction, missing passthrough content became an empty
typed layout that Core preserved as if it were a recording. Location's layout
lacks its required initial access segment, so mixed record/passthrough publication
failed during strict encoding. Systems whose empty tracks are valid instead
produced misleading recordings that could later satisfy replay membership.

Startup now carries the selected usable baseline's attachment identities into
Core through a package-visible entry point. An absent or unusable baseline
contributes no identities. Core excludes only passthrough attachments absent from
that baseline when constructing its candidate seed; the full layout remains in
preparation, activation, dependency lookup, diagnostics, usage, and cleanup.
Finalization therefore produces the same attachment membership for in-memory
results and optional whole-document publication.

Existing passthrough recordings remain unchanged, including valid recordings
with empty tracks. Record and replay membership is unchanged. Baseline membership
is explicit; no record-count heuristic or Location validation exception is used.
The public Core start path continues to treat its supplied definition as
authoritative content. There is no public API, dependency, persistence schema,
platform-floor, or native lifetime change.

Healthy publication summaries count the resulting definition's attachments and
tracks. Ordered execution usage still includes every configured system.
Unhealthy attempts retain the existing usage-based attempted counts and
whole-candidate suppression.

During owner review, a behavior-preserving clarification gives the summary
explicit candidate-versus-attempted membership branches and documents their
meaning at the public summary type. Existing passthrough and publication-report
tests cover both healthy output counts and unhealthy attempted counts.

## Regression evidence

Before the production change, the new public consumer suite fails on attachment
membership, candidate counts, all-passthrough output, and acceptance of omitted
content for replay. After the change, it proves:

- Fresh in-memory, explicit partial baseline, missing repository, malformed
  repository, and loaded partial baseline behavior, with both default and
  overridden passthrough selection.
- Passthrough activation and ordered usage/cleanup despite output omission;
  successful publication with matching decoded and in-memory attachment sets.
- Preservation of an empty baseline recording while a separately keyed new
  instance of the same system is omitted. Existing publication tests continue
  to prove nonempty replay/passthrough baseline preservation and immutability.
- Fresh all-passthrough runs return an empty definition without writing.
  Switching an omitted system to replay refuses startup before activation.
- Controlled native Location recording alongside native passthrough, both
  with and without existing passthrough content, in memory and through files.
  Live object identity and shutdown are retained; strict encoding/decoding
  succeeds, baseline content survives, and the recorded system replays offline
  without modifying file bytes or constructing its native driver.

## Verification and review boundary

- Focused consumer/publication, native Location, and Core candidate suites pass.
- The preparatory `Resolution` refactor independently passes the existing setup
  and repository startup suites before baseline membership is added.
- `scripts/check` passes formatting, strict lint, all 614 host tests, coverage
  tooling fixtures, public authoring/lifecycle compiler probes, warning-free
  release builds, and both runnable command-line examples.
- `git diff --check` passes.

Verification is local macOS evidence. No additional local iOS or Linux run is
claimed; the full macOS, iOS, and Linux matrix is the required PR CI gate.
The owner approves stacked PR creation on 2026-11-07.
This branch is stacked on the Location startup fix in PR #117. Review the C08
diff against `fix/location-fresh-recording`. Three C08 commits separate the
approved design/plan amendment, the behavior-preserving `Resolution` refactor,
and the implementation, tests, and evidence. The refactor introduces only the
definition and diagnostics fields; the behavior commit adds baseline membership
and its use.
A documentation-only fixup records PR authorization and the final plan status.
