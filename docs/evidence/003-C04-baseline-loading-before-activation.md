# 003-C04: Baseline loading before activation

- Date: 2026-09-18
- Plan: [003-C04](../plans/003-clean-slate-implementation.md#003-c04--baseline-loading-before-activation)
- Status: Implementation and available local platform verification complete;
  owner review is the next checkpoint.
- Authority: [Decision 7](../design-decisions/07-persistence-boundary.md),
  [Decision 8](../design-decisions/08-schema-compatibility.md),
  [Decision 9](../design-decisions/09-normalization-and-redaction.md),
  [Decision 10](../design-decisions/10-lifecycle-and-ownership.md), and the
  owner's scope and GPT-5.6 Sol / high reasoning confirmation on 2026-09-17.
- Base: C03 commit `df47498`, atop C01 through C03 while those units remain
  under owner review.

## Delivered boundary

`JSONScenarioRepository.start(configuredBy:systems:sink:)` is the explicit
repository-backed counterpart to the existing programmatic
`ScenarioExecution.start` path. It validates persistence registration before
storage access, loads exactly once, resolves the full effective-mode policy,
assembles one strict definition, and then delegates to the existing prepare-all
before activate-any lifecycle.

The returned `RepositoryScenarioExecution` retains both the running execution
and the exact `ScenarioLoadResult`. A failed start retains either the exact load
result or the pre-load `PersistenceDispatchError` alongside the existing safe
startup and rollback report. Underlying storage and codec errors remain typed
evidence and are never rendered into diagnostics.

Loaded content is authoritative for stable values. Runtime setup continues to
own scenario identity, attachment order, effective modes, current preparation
policy, and ignored keys. Configured attachments absent from a valid document
retain an empty typed layout. After the complete document has been registered,
decoded, prepared, and validated, each loaded attachment absent from setup
produces a safe diagnostic and is discarded from the resolved definition. The
exact retained `ScenarioLoadResult` still describes what the repository read;
future candidate construction must omit the diagnosed unmatched attachments.

Repository startup performs no publication, staging, directory creation, or
other write. A later unit owns candidate construction and publication.

## Effective-mode policy

The complete startup policy is:

| Repository result | Effective replay exists | Effective record exists | Passthrough only |
| --- | --- | --- | --- |
| Valid loaded content with every replay attachment | Start from the authoritative loaded content after current-policy preparation. | Start; a configured record attachment absent from the document begins empty. | Start without requiring persisted content. |
| Valid loaded content missing a replay attachment | Refuse before any system callback. | Not applicable when no replay exists; missing record content starts empty. | Start. |
| Missing document | Refuse before any system callback. | Start as a normal first recording with no loss warning. | Start. |
| Unreadable, invalid, incompatible envelope, or incompatible system | Refuse the entire mixed-mode startup before any system callback. | Rebuild from empty configured tracks and emit a nonfatal preservation-loss diagnostic. | Start without a preservation warning. |
| Loaded content conflicts with runtime attachment identity | Refuse the entire mixed-mode startup before any system callback. | Treat as unusable, rebuild empty, and emit the same nonfatal preservation-loss diagnostic. | Start without a preservation warning. |

Any one replay attachment makes an unusable baseline fatal for the whole
execution. There is no partial replay or live fallback. A valid empty track is
usable replay content and activates normally; a valid document that omits the
replay attachment is a distinct pre-activation failure.

For every valid loaded-content row, unmatched loaded attachments are diagnosed
and discarded before activation. The diagnostic is nonfatal and does not make a
recording candidate unhealthy. Because only configured attachments enter the
resolved definition, they are absent from execution usage and a later healthy
publication can remove them from the Git-backed file.

Before loading, every configured attachment must have a persistence
registration. Ignoring a configured attachment affects later verification only
and does not bypass this check. The loader separately requires registration and
full validation for every loaded payload, including an attachment that will be
discarded as unmatched. A setup registration failure reads no storage and
invokes no runtime callback.

When record mode rebuilds from nonmissing unusable input, the safe diagnostic
states that preservation was lost. This fact alone does not invalidate the new
recording candidate. Missing input is an expected first-recording state and is
not diagnosed. In every case the destination remains untouched at startup.

## Executable evidence

The focused tests prove:

- exact loaded-result retention, one repository read, zero writes, and
  authoritative replay values;
- refusal for missing, unreadable, malformed, incompatible-envelope, and
  incompatible-system replay input before preparation or activation;
- valid empty replay versus a valid document missing the configured replay
  attachment;
- whole-execution refusal for mixed record/replay setup;
- record rebuilding with empty typed tracks, safe nonfatal loss evidence, and
  no destination mutation;
- normal missing-first-recording and passthrough behavior;
- pre-load registration refusal, including an ignored active attachment;
- exact load evidence for unmatched content plus one safe discard diagnostic
  per unmatched attachment and no corresponding execution usage;
- reapplication of current runtime preparation policy before activation;
- setup-owned order and modes, baseline-owned matching values, mismatch
  rejection, and unmatched attachment discard; and
- stable rendering for every baseline problem without underlying error text.

## Verification

- `scripts/check` passes formatting, strict lint, all 142 macOS test functions,
  and main and examples release builds with warnings as errors.
- `scripts/coverage swiftpm macos` passes and exports LCOV. The new repository
  startup orchestration covers 136 of 149 executable lines (91.28%); all nine
  touched production files collectively cover 961 of 1,022 executable lines
  (94.03%).
- `scripts/coverage ios` passes the iOS 18 deployment build and all 142 test
  functions on the selected iPhone 17 / iOS 27.0 simulator, then exports LCOV
  with the same touched-file coverage. Xcode emits only its tool-generated App
  Intents metadata notice for bundles without that dependency.
- The policy's pinned x86_64 Apple Container command passes all 142 Linux test
  functions, both release builds, and multi-binary LCOV export using
  `swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`,
  two CPUs, 4 GiB memory, a read-only repository mount, and a writable copy of
  package inputs.
- Local Markdown link targets and the complete C04 diff whitespace check pass.

The actual local Apple toolchain is Xcode 27.0 stable, build `27A266a`, with
Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`). This branch still
inherits the beta-6 pin from C03. The separate stable-toolchain update is not
part of C04, and these local Apple results do not claim to verify the inherited
pin. Hosted CI and Codecov upload evidence require the separately authorized PR
workflow; this unit makes no remote changes.

## Deferred work

C04 does not introduce unified setup convenience, candidate construction,
preservation merging, publication, live replay fallback, partial replay,
resource loading, or a policy that treats merely unused data as a test failure.
Those concerns remain with their later approved units.
