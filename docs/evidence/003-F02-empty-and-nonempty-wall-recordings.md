# 003-F02: Empty and nonempty wall recordings

- Date: 2026-10-03
- Status: Complete; the owner authorized pull request creation on 2026-10-03.
- Authority: The owner's confirmation of 003-F02 scope and GPT-6 Sol at
  `high` reasoning, followed by approval of the Core track-header and
  overridable-value prerequisites and dated-track review change on 2026-10-03;
  [Decisions 3](../design-decisions/03-recorded-behaviors.md),
  [8](../design-decisions/08-schema-compatibility.md), and
  [15](../design-decisions/15-clock-system.md); and the
  [approved plan](../plans/003-clean-slate-implementation.md#003-f02--empty-and-nonempty-wall-recordings).
- Review base: `master` at `c1fef7e`, with both Core prerequisites merged.

## Delivered boundary

`DioramaClock` now owns a validated wall recording model and the deliberate
`diorama.clock` payload schema version 1. An empty declared wall track has no
origin. A nonempty in-memory track stores absolute `Date` observations in Core
`OverridableValue<Date>` values and a typed header for the origin's numeric UTC
offset. The Core prerequisites provide typed headers that travel with their
tracks through admission, recording, and candidate finalization, plus a general
effective value and override marker without persistence policy. The codec
translates the dated sequence to the persisted origin and
positional signed deltas. The semantic builder requires position zero to be
`0ms`, or normalizes an authored position-zero override into an origin override
and ordinary `0ms`.
It validates checked cumulative `Int64` arithmetic and representable effective
`Date` values. Effective absolute dates are available in observation order.

The codec uses 003-F01's origin and duration scalars. It accepts ordinary
observed strings and the declared explicit `observed`/`override` editing form,
then writes only the one effective canonical form. It rejects unknown payload
fields and tags, missing or malformed fields, invalid origin/delta combinations,
cumulative overflow, and unsupported clock versions. The
[schema reference](../date-schema-v1.md) and committed
[empty](../../Tests/DioramaDateTests/Fixtures/date-empty.json),
[nonempty](../../Tests/DioramaDateTests/Fixtures/date-nonempty.json), and
[edited](../../Tests/DioramaDateTests/Fixtures/date-edited.json) fixtures
protect the version-one output and tolerant normalization.

`DioramaPersistence` supplies conditional `Codable` conformance for the shared
`OverridableValue` editing form. The wall payload stores that Core value
directly, while the clock's version-one envelope and scalar validation remain
local to `DioramaClock`. The shared form reserves top-level `observed` and
`override` keys; systems with raw values using those keys need their own codec.

This slice adds no wall source, replay service, scheduler sleeps, or third-party
dependency. Those operations retain their later Phase F boundaries. The core
package remains independent of persistence.

## Verification

| Gate | Local result |
| --- | --- |
| Focused Core suite | Two `OverridableValue` tests pass, covering effective values, authorship, conditional equality, and case-preserving mapping. The full Core suite passes. |
| Focused wall suite | Eight tests pass on macOS. They include dated-track round trips, parameterized malformed inputs, unknown fields/tags, and version rejection. |
| Shared field coding | Three focused persistence tests pass for scalar and structured values, canonical override output, and unknown-key rejection. The clock's golden fixtures remain unchanged. |
| Rebase integration | After restacking onto `c1fef7e`, the focused wall suite and canonical `scripts/check` pass on macOS with the current typed header API. |
| Formatting and lint | The canonical `scripts/check` passes, including SwiftFormat and strict SwiftLint. Strict SwiftLint also passes independently with `--no-cache`. |
| macOS tests and release builds | The full host suite passes with warnings treated as errors. The package and example release builds pass; the example runs. |
| macOS coverage | `scripts/coverage swiftpm macos` passed its full test and release-build gates and exported LCOV before the rebase. |
| iOS Simulator | `scripts/coverage ios` passed its Release build, complete simulator suite, and LCOV export on iPhone 17 / iOS 27.0 with the iOS 18 deployment floor before the rebase. |
| Linux | Docker is installed but its daemon is unavailable locally. The required Linux test and coverage job runs in PR CI. |

Apple verification uses Xcode 27.0 (`27A266a`) and Apple Swift 6.4
(`swiftlang-6.4.0.34.1`). The simulator result proves behavior on the installed
iOS 27 runtime with an iOS 18 compile-time floor; it does not establish behavior
on an iOS 18 installation. Required PR CI is the integration gate for Linux and
the final revision.

## Review boundary

The review base contains both Core prerequisites and their focused tests.
The implementation commit contains the clock product, semantic model,
registered codec, schema contract, and proving tests and fixtures. A separate
documentation commit records this evidence and the owning plan's unit status.
The owner authorized PR creation on 2026-10-03. The complete feature-branch
diff against `master` is the review surface.
