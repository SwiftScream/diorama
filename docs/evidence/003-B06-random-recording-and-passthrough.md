# 003-B06: Random recording and passthrough

- Date: 2026-09-13
- Authority: Owner confirmation of 003-B06's scope and GPT-5.6 Sol at `high`
  reasoning, with explicit authorization to develop it as a stacked unit atop
  B05 while B04 remains under review.
- Status: Complete; final owner review pending.
- Prerequisites: [B05 evidence](003-B05-consumer-module-extension-proof.md),
  [DD06](../design-decisions/06-runtime-to-snapshot-conversion.md),
  [DD09](../design-decisions/09-concurrency-and-cancellation.md), and
  [DD13](../design-decisions/13-random-proving-system.md).

## Review boundary

This unit adds the production `DioramaRandom` library product and target with an
ordinary dependency on `DioramaCore`. It implements live recording and
passthrough entirely through the public extension boundary proved by B05. No
production `DioramaCore` source changed.

`DioramaRandomNumberGenerator` is a public, reference-semantic,
`Sendable` `RandomNumberGenerator`. `DioramaRandomSystem` exposes stable system,
attachment, and track identities; an empty attachment helper; a registration
using `SystemRandomNumberGenerator`; and a registration accepting a `@Sendable`
factory for an injected `RandomNumberGenerator & Sendable`. The compiled API
documentation includes the intended injection form.

## Live-source and lifecycle behavior

- Each successful execution activation constructs one fresh live source. The
  factory is not evaluated during definition, preparation, or rejected replay
  setup.
- One attachment lock serializes source reads. In record mode that lock spans
  both the live read and the public typed-track append, so source order and
  recorded order cannot diverge. A late stable-admission failure preserves the
  already observed live return value while core health evidence prevents an
  unhealthy recording from being published.
- Passthrough reads the live source without invoking a track operation or
  changing existing track content.
- References to one generator share its source and record order. Separately
  keyed attachments and separate executions own independent state.
- Finalization closes the lease and detaches the source. Source destruction
  occurs outside the source lock. An escaped generator reports the established
  closed-lease lifecycle fact and returns zero without reading the released
  source.
- Replay setup records the safe
  `random-replay-unavailable-before-b07` system diagnostic and fails before
  creating a live source. B07 owns offline replay, exhaustion, and its
  deterministic failure policy.

The implementation adds no unsafe sendability or isolation annotation,
detached task, availability exception, third-party dependency, seed,
distribution, timing value, persistence schema, or cryptographic claim.

## Verification

- The focused `DioramaRandomTests` suite passes eight tests covering a known
  source sequence, shared reference semantics, passthrough without track
  mutation, independent named sources, fresh source state for each execution,
  100 concurrent calls with a measured maximum of one live source operation,
  source release and escaped-generator closure, replay rejection without source
  construction, and the default system source.
- `scripts/check` passes formatting, strict lint with zero violations, all 57
  host tests across the random, core, and consumer test modules, and
  warnings-as-errors debug and release builds under the selected Apple
  toolchain.
- `swift test -c release -Xswiftc -warnings-as-errors` passes all 57 tests under
  optimization.
- `scripts/coverage swiftpm macos` passes all 57 tests and its release build and
  writes `.build/coverage/macos.lcov` containing every discovered test
  executable's source mappings, including `DioramaRandom`.
- `scripts/coverage ios` passes the release build and all 57 tests (74
  invocations including parameterized cases) on the selected iPhone 17 / iOS
  27.0 simulator with the iOS 18 deployment-floor setting. The result bundle
  contains no failures, skips, expected failures, or runtime warnings and
  includes coverage. The canonical script now selects Xcode's generated
  `Diorama-Package` scheme so every library and test target participates after
  the second public product was added.
- The Linux gate passes `Spikes/ToolchainAvailability/run linux`, all 57 tests,
  the warnings-as-errors release build, and coverage export through
  `scripts/coverage swiftpm linux` in an Apple Container x86_64 guest limited
  to two CPUs and 4 GB. The guest uses the digest-pinned `swiftlang/swift` image
  `sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`,
  Ubuntu 24.04.4 LTS, Swift 6.4.2-dev (LLVM `15622a86b1749a9`, Swift
  `d2e983b81b18217`), and `libcurl4-openssl-dev` 8.5.0-2ubuntu10.13. The
  repository is mounted read-only and copied to an isolated directory inside
  the ephemeral guest before the gate runs.
- Local Markdown targets exist and the complete B06 diff passes
  `git diff --check` against its B05 stack base.

The required hosted Quality, macOS, iOS, Linux, and Codecov evidence is
collected through this unit's final-review PR. Local simulator and host
executions do not establish runtime behavior on actual macOS 15 or iOS 18
installations.

## Exclusions and next boundary

B06 does not implement replay, exhaustion policy, persistence, seeds,
distributions, clocks, native adapters, or automatic unused-record accounting.
B07 may now add offline raw-value replay through the same public sequential
claim boundary; it is not started by completion of B06.
