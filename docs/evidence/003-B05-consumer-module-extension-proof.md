# 003-B05: Consumer-module extension proof

- Date: 2026-09-13
- Authority: Owner confirmation of 003-B05's scope and GPT-5.6 Sol at `high`
  reasoning, with explicit authorization to develop it as a stacked unit while
  B04 remained under review. The owner completed initial B05 review and
  authorized its rebase, squash, and pull request on 2026-09-13 after B04 merged.
- Status: Implementation complete; initial owner review complete and final pull
  request review remains.
- Prerequisites: [B04 evidence](003-B04-atomic-sequential-operations.md),
  [DD02](../design-decisions/02-shared-vs-system-semantics.md), and
  [DD13](../design-decisions/13-random-proving-system.md).

## Review boundary

This unit proves that the public sequential extension boundary delivered by
B01 through B04 is usable from a distinct consumer module. The new
`DioramaConsumerTestSupport` target is a regular Swift target with an ordinary
dependency on `DioramaCore`, but it is not part of a library product. Its source
lives under `Tests` and exists only as executable conformance evidence.

The target defines a synchronous consumer system, a reference-semantic
dependency, and a `Sendable` stable value that deliberately has no `Codable`
conformance. It imports `DioramaCore` normally and uses no `@testable` import,
SPI, package access, or source-level friendship. The proof required no change
to production `DioramaCore` source.

## Public-only system path

- Consumer-authored helpers declare one stable system type, caller-keyed
  attachment identities, and one typed values track per attachment using
  `ScenarioAttachment`, `SequentialTrack`, and `ValuePreparation`.
- `ScenarioSystem` preparation obtains the effective mode and a typed lease
  through `SystemPreparationContext`. `PreparedSystem` activation publishes a
  fresh `ConsumerSequentialDependency`, and `SystemActivation` supplies its
  synchronous cleanup obligation.
- In record mode, one dependency call delegates live capture and stable
  preparation to `SequentialTrackLease.append`. In replay mode it returns the
  next public `SequentialRecord` from `claimNext` without evaluating the live
  closure. In passthrough it evaluates the live closure without invoking a
  track operation.
- Separately keyed instances receive independent leases, modes, and cursors.
  Registration-list order does not affect attachment identity or replay order.
- The dependency contributes a capability-defined unused-record fact through
  public structured diagnostics before finalization. This proves that a
  consumer system can participate in verification without assigning a test
  outcome. B08 remains responsible for automatic core usage accounting and
  unused-record evaluation.
- Explicit finish closes the consumer's lease and records successful cleanup.
  A retained dependency refuses a later live closure, reports the common
  `leaseClosed` lifecycle fact to the separate post-finish log, and returns its
  own typed closure failure.

The proof adds no unsafe sendability or isolation annotation, detached task,
availability exception, third-party dependency, production product, or
production manifest dependency.

## Verification

- The focused `ConsumerSequentialSystemTests` suite passes four tests covering
  non-`Codable` record/replay, zero live replay access, passthrough behavior,
  independent named attachments, mode overrides, consumer diagnostics,
  cleanup, and post-finish closure.
- Source inspection finds only ordinary `import DioramaCore` declarations in
  the consumer support and conformance-test targets, with no `@testable` or SPI
  import. Successful compilation of the regular target therefore checks the
  public access-control boundary.
- `scripts/check` passes formatting, strict lint with zero violations, all 49
  host tests across the core and consumer test modules, and warning-free debug
  and release builds under the selected Apple toolchain.
- `swift test -c release -Xswiftc -warnings-as-errors` passes all 49 tests under
  optimization.
- `scripts/coverage swiftpm macos` passes all 49 tests, its release build, and
  writes `.build/coverage/macos.json`.
- `scripts/coverage ios` passes the release build and all 49 tests (66
  invocations including parameterized cases) on the selected iPhone 17 / iOS
  27.0 simulator at the iOS 18 deployment floor. The result bundle contains no
  failures, skips, expected failures, or runtime warnings.
- The Linux gate passes `Spikes/ToolchainAvailability/run linux`, all 49 tests,
  the warnings-as-errors release build, and coverage export through
  `scripts/coverage swiftpm linux` in an Apple Container x86_64 guest limited
  to two CPUs and 4 GB. The guest uses the digest-pinned `swiftlang/swift` image
  `sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`,
  Swift 6.4.2-dev (LLVM `15622a86b1749a9`, Swift `d2e983b81b18217`), and
  `libcurl4-openssl-dev` 8.5.0-2ubuntu10.13. The repository is mounted read-only
  and copied to an isolated directory inside the ephemeral guest before the
  gate runs.
- Local Markdown targets exist and the complete B05 diff passes
  `git diff --check` against the merged B04 revision on `master`.

The B05 pull request passes the required hosted Quality, macOS, iOS, Linux, and
Codecov checks. Local simulator and host executions do not establish runtime
behavior on actual macOS 15 or iOS 18 installations.

## Exclusions and next boundary

B05 does not ship the proving system as a product and does not implement Random,
persistence, automatic unused-record accounting, arbitrary replacement
behavior engines, or a broader system protocol. B06 may now build Random's live
recording and passthrough behavior through the same proved public boundary; it
is not started by completion of B05.
