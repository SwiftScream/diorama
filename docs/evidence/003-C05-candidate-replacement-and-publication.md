# 003-C05: Complete candidate replacement and final publication

- Scope and model confirmed: 2026-09-22
- Model: GPT-6 Astra, `high` reasoning
- Status: Complete; implementation and local platform verification complete on 2026-09-22
- Owning unit: [003-C05](../plans/003-clean-slate-implementation.md#003-c05--complete-candidate-replacement-and-final-publication)
- Governing decisions: [DD07](../design-decisions/07-persistence-boundary.md),
  [DD10](../design-decisions/10-lifecycle-and-ownership.md),
  [DD13](../design-decisions/13-random-proving-system.md), and
  [DD18 and its consumer amendments](../design-decisions/18-diorama-setup-and-scenario-data.md)

## Semantic output

Core finalization transfers admitted record-mode values out of closed sequential
leases into one immutable `ScenarioDefinition`. New recordings replace whole
tracks, including replacement by an empty track. Replay and passthrough preserve
their configured baseline tracks independently of consumption. Unused-record
waivers do not remove content. Startup's reconciled membership remains
authoritative, so unconfigured attachments do not reappear in the result.

Each replacement originates in the typed lease prepared for that exact track.
Values have already passed capture preparation; finalization does not transform
them again. Attachment order, track order, and observation sequence remain
deterministic. The input definition remains immutable. Any candidate-invalidating
fact in the frozen core report suppresses the whole resulting definition,
including an observation whose reserved position was still incomplete when its
lease closed. Partial admitted sequences are not exposed as healthy definitions.

`ScenarioFinalizationResult.definition` owns only stable semantic values. Leases
release their content and runtime dependencies release their sources and cleanup
captures. The result may outlive the execution without retaining its machinery.
Safe report rendering and evaluation do not inspect payloads. Because semantic
values require only `Sendable`, the finalization result no longer conforms to
`Equatable`; callers may compare its safe report, usage, and cleanup fields, or
inspect system-specific content explicitly.

## Consumer publication

`DioramaResult.definition` exposes the core result directly. Its separate
`publication` field has four dispositions:

| Disposition | Meaning |
| --- | --- |
| `notRequested` | In-memory setup, or no effective record-mode attachment. |
| `refusedUnhealthy` | Requested publication has no complete healthy definition. |
| `published` | The complete document committed; its receipt retains any subsequent storage cleanup evidence. |
| `failed` | Encoding or storage failed before commit; the healthy semantic definition remains available. |

File and repository setup request publication when at least one configured
attachment has effective record mode. Each scoped consumer execution calls core
finalization once, then makes one publication attempt. Cancellation of the
scoped caller does not skip publication, and a failed publication is not retried.
Core's explicit `ScenarioExecution.finish()` remains idempotent for its own
concurrent callers.

Core completes adapter cleanup and freezes semantic output before the consumer
layer invokes the existing repository's whole-document publication. The
repository encodes the complete definition before invoking atomic storage.
Replay and passthrough alone perform no writes. Unhealthy candidates perform no
encoding or storage operation. A valid definition remains usable directly by
another in-memory execution after encoding or storage failure.

The latest DD18 scoped error contract remains in force: successful bodies
return `DioramaResult`; body errors are rethrown after finalization and configured
publication. Thus body failure or cancellation alone does not suppress a healthy
publication, but a throwing body does not return a result object. Startup errors
still prevent body invocation. C06 owns the broader stage-specific diagnostic
reporting and fault-injection matrix; C05 exposes publication evidence explicitly
without automatically rendering arbitrary backend errors.

The random example now transfers the resulting definition into replay without
manually reconstructing tracks. It also demonstrates a temporary file workflow
whose recording body returns no observations, then removes that temporary file.

## Added verification coverage

The proposed tests exercise:

- complete replacement, empty recording, immutable input, deterministic content,
  and preserved replay/passthrough tracks;
- a failed track suppressing the entire definition and a preparation operation
  racing the recording horizon;
- stable content retained by the result while adapters, escaped contexts, and
  closed leases release execution resources;
- direct heterogeneous record-to-replay, including a consumer type without
  persistence conformance;
- configured ignored tracks, omitted attachments, record-only rebuilding,
  no publication before finish, and no replay/consumption writes;
- real random file recording, replay, and replacement by a later empty recording;
- valid semantic output surviving encoding or storage failure;
- success, throwing bodies, cancellation errors, and canceled bodies that return,
  each with healthy and unhealthy recording; and
- a scoped caller canceled during publication still receiving its body value and
  healthy definition after one publication attempt, on both success and storage
  failure.

## Verification

The initial C05 revision passed the full macOS, iOS Simulator, and Linux matrix
on 2026-09-22, with 189 tests in 37 suites on each platform. The 2026-09-23
review revision removes the consumer run's redundant finish cache and tests
single scoped publication through the public operation. Its focused test and
canonical macOS gate pass. macOS coverage contains 2,372 covered lines of 2,425
executable source lines (97.81%). These local measurements are separate from
hosted Codecov's PR comparison.

| Check | Result |
| --- | --- |
| Focused review test | Pass: both successful and failed publication after caller cancellation. |
| `scripts/check` | Pass on the review revision: canonical formatting, strict lint, strict-concurrency builds, all 189 macOS tests, and release example build. |
| `scripts/coverage swiftpm macos` | Pass on the review revision: all 189 tests, release builds, and LCOV export. |
| `scripts/coverage ios` | Pass on the initial revision: all 189 tests on iPhone 17 / iOS 27 Simulator, release build, and LCOV export. |
| Pinned Linux container running `scripts/coverage swiftpm linux` | Pass on the initial revision: all 189 tests, release library and example builds, and LCOV export. |
| Release `DioramaRandomUsage` example | Pass: recorded and replayed arrays match; temporary file recording and replay complete successfully. |
| `scripts/verify-apple-toolchain` | Pass: Xcode 27.0 (`27A266a`), Apple Swift 6.4, and the configured iOS 27 Simulator runtime. |
| Complete branch diff whitespace and local documentation links | Pass. |

Xcode emits five App Intents metadata-extraction warnings for test bundles
without an AppIntents framework dependency. Swift compiler and SwiftLint checks
pass with warnings treated as errors.

Linux uses the exact x86_64 Swift 6.4 image, two CPUs, 4 GiB memory, and read-only
source mount prescribed in the quality policy:
`swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`.
Compilation and coverage export run in the container's temporary working copy;
the local Linux LCOV file is not retained after the container is removed.

## Review boundary

The two commits separate core candidate finalization and its tests
from consumer publication, integration tests, the random example, and this
unit's plan/evidence updates. The whole branch is the C05 review unit.

No dependency, schema version, deployment floor, unsafe concurrency annotation,
or quality-gate exception is introduced. Resource-backed publication and other
systems' override merge behavior remain with their owning later units.
