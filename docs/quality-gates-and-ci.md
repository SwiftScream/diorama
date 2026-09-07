# Quality gates and CI policy

- Status: Accepted
- Last updated: 2026-09-06
- Reference project: [SwiftScream/URITemplate](https://github.com/SwiftScream/URITemplate)

## Purpose

Diorama should establish formatting, linting, builds, tests, and coverage before
feature implementation begins. Every later atomic implementation task should
use the same local and CI checks rather than introducing quality automation
after substantial code exists.

This is a delivery policy rather than a runtime design decision.

## Tools

Use these complementary tools:

- [nicklockwood/SwiftFormat](https://github.com/nicklockwood/SwiftFormat) is the
  authoritative automatic source formatter.
- [realm/SwiftLint](https://github.com/realm/SwiftLint) enforces documentation,
  correctness, and style rules that formatting does not cover.
- [yonaskolb/Mint](https://github.com/yonaskolb/Mint) installs and invokes exact
  tool versions from a committed `Mintfile`.

The tools should not be dependencies of Diorama library targets or additions to
the main package dependency graph. Their source, purpose, and pinned versions
must be recorded under the
[dependency approval policy](dependency-policy.md) before the bootstrap task
adds them.

The initial `.swiftformat` and `.swiftlint.yml` should use URITemplate's
configuration as an organizational baseline, then make deliberate Diorama
adjustments. In particular:

- CI runs `swiftformat --lint` so formatting drift fails without modifying the
  checkout;
- developers have a separate command that applies formatting;
- CI runs `swiftlint --strict`;
- generated files and build directories are excluded explicitly;
- public documentation checking begins with the first public library surface;
- overlapping formatter and linter style rules are disabled in one tool rather
  than producing conflicting fixes.

Lint and formatting may run on macOS only. Both tools support broader platforms,
but one deterministic quality job is sufficient; Linux remains a required
build and test platform.

## Local entry points

The repository should provide small version-controlled commands, conceptually:

```text
scripts/format       # applies SwiftFormat
scripts/lint         # non-mutating SwiftFormat and strict SwiftLint checks
scripts/test         # tests on the current host
scripts/check        # non-mutating local quality, build, and test gate
```

Exact names can follow existing SwiftScream convention if another convention
is preferred. CI must invoke these entry points or the same subordinate
commands so local success and CI success do not represent different policies.
The scripts should fail on the first failed stage and print the failing command
clearly.

Mint bootstrap must be explicit. A missing Mint executable should produce a
short installation instruction rather than silently downloading executable
code during every local check.

## Toolchain policy

Diorama should use the latest stable Swift and Xcode releases selected when the
clean implementation is bootstrapped. "Latest" means the newest stable release,
not a beta or nightly toolchain.

The selected versions should be explicit in CI configuration and recorded in
the repository. Floating runner labels alone are insufficient because their
default Xcode and Swift versions can change without a source revision. Version
updates should be small, deliberate maintenance changes that run the complete
matrix.

The initial package should use Swift 6 language mode and the latest stable
Swift tools version selected at bootstrap. The macOS and Linux jobs should use
the same Swift release where practical. A future non-blocking compatibility job
may exercise an upcoming toolchain, but beta compatibility is not an initial
merge requirement.

## Concurrency checking

All Diorama targets should compile in Swift 6 language mode with complete strict
concurrency checking. Concurrency warnings must not be deferred as migration
work in a new package, and CI must build both debug and release configurations
early enough to expose isolation or sendability differences.

Diorama should adopt the parts of Swift's approachable-concurrency model that
improve library semantics:

- enable `NonisolatedNonsendingByDefault` so an ordinary nonisolated async API
  remains on its caller's executor unless it deliberately declares concurrent
  execution;
- enable `InferIsolatedConformances` where supported by the selected stable
  toolchain;
- use `@concurrent` only when an API intentionally moves work away from the
  caller's actor and its values can safely cross that boundary;
- use `sending`, `Sendable`, actors, and explicit isolation to express real
  ownership transfers rather than suppress diagnostics.

The default actor isolation should remain nonisolated for Diorama's library
targets. Default `MainActor` isolation is intended primarily for UI,
application, and other predominantly single-threaded modules. Applying it to
the core, HTTP, scheduler, random, or URLSession products would make a
cross-platform infrastructure library main-thread-bound by default and would
obscure rather than clarify its concurrency contract. A future target with a
genuinely main-actor-bound native API can opt in independently or annotate only
the relevant adapter declarations.

`@unchecked Sendable`, `nonisolated(unsafe)`, broad `@preconcurrency` imports,
and detached tasks are reviewed exceptions, not routine fixes for compiler
errors. Each use should document the external synchronization or ownership
invariant that makes it sound and receive focused tests. The implementation
should prefer structured tasks owned by the scenario execution and explicit
adapter isolation.

Experimental compiler diagnostics such as requiring explicit public
`Sendable` declarations may be evaluated in CI. They should not be embedded as
unsafe package target flags unless the selected stable toolchain and package
distribution behavior make that appropriate.

Swift toolchain support and Apple deployment support are separate promises.
The package uses the selected current stable toolchain while declaring the
minimum runtime versions below; newer compilers do not make unavailable runtime
clock APIs usable on older operating systems.

### Apple deployment minima — owner-approved amendment, 2026-09-06

The owner approved moving the initial iOS minimum from 15 to 16, together with
the equivalent Apple platform versions, to support the `ContinuousClock` and
Swift `Clock` contracts in Decisions 14 and 15 without a substitute clock.

| Platform | Minimum deployment version | Initial support |
| --- | --- | --- |
| iOS / iPadOS | 16.0 | Required iOS Simulator build and test job. |
| macOS | 13.0 | Required native build and test job. |
| Mac Catalyst | 16.0 | Availability floor only; not newly advertised or tested. |
| tvOS | 16.0 | Availability floor for separately approved future support. |
| watchOS | 9.0 | Availability floor only; Decision 12 still excludes URLSession interception here. |
| visionOS | 1.0 | Availability floor for separately approved future support. |

The deployment change does not add required platform jobs or expand any
adapter's tested capability profile. Linux remains required under its explicitly
selected Swift/toolchain/runtime matrix. Bootstrap must verify these minima
with the chosen stable toolchain and document any narrower API availability.

## Platform matrix

Every pull request and protected-branch push should run these required jobs:

| Job | Purpose |
| --- | --- |
| Quality | SwiftFormat check and strict SwiftLint using the pinned Mintfile on macOS. |
| macOS | Build and test all products supported on macOS with the selected stable Xcode/Swift toolchain. |
| iOS | Build and run applicable tests in an iOS simulator using the selected stable Xcode. |
| Linux | Build and test all applicable products with the matching stable Swift release. |

The iOS package deployment target should initially be iOS 16. CI should compile
the package with that deployment target so unavailable API use is rejected.
The executable test run may use the current simulator runtime supplied with the
selected Xcode; current hosted runners may not provide an iOS 16 simulator.
This proves compile-time availability and current-runtime behavior, but not
runtime behavior on an actual iOS 16 installation. A platform-specific feature
whose behavior may differ on iOS 16 requires separate targeted evidence.

The iOS job must use `xcodebuild` or an equivalent Xcode test mechanism against
an iOS Simulator destination. A macOS `swift test` job is not evidence that
Foundation, Core Location, or URLSession integration works on iOS.

The Linux job should use an explicitly selected official Swift toolchain or
container rather than whatever Swift version happens to be preinstalled on a
floating Ubuntu runner. Its FoundationNetworking integration tests are part of
the URLSession capability evidence from decision 12.

Platform-limited systems remain conditional products or targets. A missing
Core Location adapter on Linux must not prevent portable core, HTTP, random, or
clock products from building and testing there.

## Coverage

Tests should collect LLVM source coverage and upload it to
[Codecov](https://codecov.io) through the official Codecov action. Upload
failure is a CI failure rather than a best-effort notification.

Coverage should be reported separately with platform flags so platform-only
adapter code is visible:

- `macos` for macOS unit and integration tests;
- `ios` for iOS simulator tests;
- `linux` for Linux unit and FoundationNetworking integration tests.

The implementation should use SwiftPM's supported coverage output discovery or
an encapsulated script rather than hard-code a test-bundle architecture path.
The iOS job may require Xcode result-bundle conversion and should hide that
mechanism behind the same repository coverage script.

The initial `.codecov.yml` can follow URITemplate's posture:

- exclude test fixtures and generated code from product coverage;
- use the previous commit as the project baseline;
- allow a small project-level tolerance for incidental movement;
- report patch coverage separately;
- require every expected platform upload before finalizing the combined status.

Coverage is a review signal and regression gate, not a target to maximize with
assertion-free tests. Exact initial thresholds should be confirmed when the
first production targets and baseline exist.

For a public repository, Codecov OIDC or tokenless upload is preferable when
the SwiftScream organization configuration supports it. Otherwise the token is
stored only as a GitHub Actions secret. It never appears in repository files or
fork pull-request logs.

## Workflow integrity

GitHub Actions workflows should:

- grant only the permissions needed by each job;
- pin third-party actions to reviewed immutable commit SHAs, with a version
  comment for readability;
- use dependency automation or deliberate maintenance changes to update those
  pins;
- cancel superseded runs for the same pull request;
- cache Mint builds and SwiftPM artifacts only where cache invalidation includes
  their manifests, selected toolchain, and platform;
- keep format/lint, platform tests, and coverage failures independently visible.

GitHub Actions are executable supply-chain inputs even though they are not
Swift package dependencies. Their sources and pin updates should be reviewable;
the package dependency allowlist does not implicitly approve arbitrary actions.

## Dependency automation

The bootstrap should add `.github/dependabot.yml` with weekly version-update
checks for:

- the root Swift Package Manager manifest using Dependabot's `swift` ecosystem;
- GitHub Actions using the `github-actions` ecosystem.

Dependabot pull requests run the complete required CI matrix and are not merged
automatically. Automation does not supersede the dependency approval policy: an
update within an approved major range receives normal review, while a new major,
product, source, or direct dependency still requires explicit owner approval.

GitHub Dependabot does not currently list Mintfile as a supported package
ecosystem. Mint pins are therefore not covered merely by enabling Dependabot
for Swift. Mint remains the tool source of truth, and a scheduled GitHub Actions
workflow runs `mint outdated` to report available updates. A maintainer applies
those updates through an ordinary reviewed pull request. This reporting
workflow should run weekly and support manual dispatch.

Maintaining a duplicate SwiftPM tools manifest solely to prompt updates to a
separate Mintfile is not recommended. It creates two version sources and still
needs synchronization machinery. A second dependency-update service should not
be introduced unless automated Mint update pull requests later demonstrate
enough value to justify it.

## Implementation order

The clean-slate plan should place this work immediately after creating the
minimal package skeleton and before implementing the random proving system:

1. add the approved and pinned Mint tools;
2. add formatter and linter configuration;
3. add local formatting, linting, test, and aggregate check entry points;
4. add macOS, iOS, and Linux workflows with a minimal test target;
5. enable coverage generation and Codecov upload;
6. require all resulting checks before broader implementation begins.

This bootstrap is itself one reviewable task. It should not also introduce
Diorama runtime architecture.

## Review points

1. **Tooling: Resolved.** SwiftFormat and SwiftLint are managed at exact
   versions by Mint, with quality checks running on macOS and no tooling
   dependencies in Diorama's main package graph.
2. **Toolchains, concurrency, and platforms: Resolved.** Use pinned
   latest-stable Swift and Xcode versions, Swift 6 language mode with complete
   strict concurrency checking, `NonisolatedNonsendingByDefault` and
   `InferIsolatedConformances`, nonisolated library defaults, iOS 16 and macOS 13
   deployment targets (amended 2026-09-06), and required macOS, iOS Simulator,
   and Linux jobs. Equivalent floors for other Apple platforms do not advertise
   additional support.
3. **Local commands: Resolved.** Provide version-controlled `format`, `lint`,
   `test`, and aggregate non-mutating `check` entry points as the canonical
   interface used by engineers, agents, and CI. Missing Mint installations
   produce instructions rather than triggering an implicit installation.
4. **Coverage: Resolved.** Require Codecov uploads with separate macOS, iOS,
   and Linux flags, baseline-relative project coverage with a small tolerance,
   and separate patch reporting. Select exact numeric thresholds once the first
   production targets establish a meaningful baseline, and prefer OIDC or
   tokenless upload where the organization supports it.
5. **Workflow integrity: Resolved.** Use least-privilege permissions, pin
   third-party actions to reviewed full commit SHAs with readable release
   comments, let Dependabot propose pin updates, cancel superseded runs, and
   key caches by their complete platform, toolchain, and manifest inputs.
6. **Dependency automation: Resolved.** Dependabot checks SwiftPM and GitHub
   Actions weekly. A weekly and manually dispatchable `mint outdated` workflow
   reports Mint updates, which maintainers apply through reviewed pull requests.

## References

- [SwiftScream URITemplate](https://github.com/SwiftScream/URITemplate)
- [SwiftFormat](https://github.com/nicklockwood/SwiftFormat)
- [SwiftLint](https://github.com/realm/SwiftLint)
- [Mint](https://github.com/yonaskolb/Mint)
- [GitHub Actions: Building and testing Swift](https://docs.github.com/en/actions/tutorials/build-and-test-code/swift)
- [Codecov GitHub Action](https://github.com/codecov/codecov-action)
- [Swift 6.2 approachable concurrency](https://www.swift.org/blog/swift-6.2-released/#approachable-concurrency)
- [SE-0461: Run nonisolated async functions on the caller's actor by default](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)
- [SE-0466: Control default actor isolation inference](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)
