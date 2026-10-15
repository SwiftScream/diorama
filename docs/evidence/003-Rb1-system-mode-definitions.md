# 003-Rb1: Typed system mode definitions

- Status: Complete; implementation and local verification completed 2026-10-16.
- Scope and PR creation: Owner-authorized on 2026-10-16.
- Contract: [DD21 typed mode amendment](../design-decisions/21-managed-native-lifecycle.md#typed-mode-definitions--owner-approved-2026-10-16).
- Unit: [003-Rb1](../plans/003-clean-slate-implementation.md#003-rb1--group-system-construction-and-lifecycle-by-mode).
- Baseline: Master includes the separate scheduler stop/disposal fix at `9aab0aa`.

## Delivered API

`SystemDefinition` requires `record`, `replay`, and `passthrough`, each returning
`SystemModeDefinition<State, Dependency>`. The declaration binds its State to
the state factory, dependency factory, and lifecycle contexts, while all modes
share the definition's Dependency type. Return types infer the associated types.
Identity, tracks, validation, and ordinary Sendable State/Dependency types remain.

The general initializer takes `makeState` and `makeDependency`, with default
no-op `requestStop` and `.completed` `cleanUp`. Two Void-State initializers supply
the empty State factory and take either a dependency factory receiving execution
services or one taking no arguments. Both accept explicit lifecycle callbacks.
Synchronous, asynchronous, and actor-isolated functions can be supplied inline
or by reference. Factory callbacks may throw; lifecycle callbacks may not.

Core obtains only the selected declaration once per activation, after all
attachments validate. It uses that declaration's factories and hooks together.
Factories still construct fresh per-execution State, and only successful returns
transfer ownership to Core. Construction-only callback captures release after
activation rather than being retained by the activated lifecycle. Failed partial
construction, successful optional nil dependencies, rollback, stop/drain/cleanup,
record freeze, and cancellation-independent finalization retain their contracts.

The previous twelve mode-specific factory/lifecycle methods are removed from the
protocol without forwarding aliases. Date, Random, both consumer proving systems,
all test definitions, compiler probes, and the current authoring guide migrate
together. Complex test fixtures retain named helpers, explicitly passed as
callbacks; first-party definitions group their short implementations inline.
Application-consumer setup, execution, persistence, and reports retain their APIs.

## Current public evidence

[SystemModeDefinitionTests](../../Tests/DioramaConsumerTests/SystemModeDefinitionTests.swift)
imports public Core alone. Its two parameterized tests cover nine invocations:

- Only the selected mode is read, once for each activation, after both
  attachments validate. Two sequential runs receive fresh State and matching
  stop/cleanup callbacks, with reverse shutdown order.
- Construction-only capture destruction is observed before startup returns.
- Both Void-State conveniences retain actor-isolated callbacks in all three
  modes, including inline execution-aware construction and named methods.
- A successfully returned optional nil dependency reaches both lifecycle
  callbacks as `.some(nil)`, with completed cleanup and no diagnostics.

The existing public startup, lifecycle, actor, scheduling, ownership, persistence,
and first-party tests run against explicitly bound mode declarations. They retain
their cancellation, factory failure, adoption, rollback, release, and report
assertions. The default lifecycle path remains exercised by Date, Random, and
consumer definitions.

The public compiler gates use current build products and configured Swift
concurrency features. Authoring retains one positive and seven negative probes.
Lifecycle retains one positive probe and now has eleven negative probes: actual
throwing stop/cleanup function signatures, incompatible State/Dependency types,
missing mode, wrong-actor access, async locked bodies, borrowed lifecycle-context
escape, and lifecycle operation effects. Every negative case requires an ordinary
compiler diagnostic; crashes and unexpected acceptance fail the gate. This
replaces the former throwing-body probes, which did not detect a mistakenly
throwing method silently leaving a default protocol witness selected.

## Verification performed

| Check | Result |
| --- | --- |
| `scripts/verify-apple-toolchain` | Pass: pinned Xcode 27.0 `27A266a`, Apple Swift 6.4, SDK and iOS runtime checks. |
| `scripts/lint` and `git diff --check` | Pass: pinned formatting, strict lint, and whitespace checks. |
| `scripts/coverage swiftpm macos` | Pass: 474 tests, both compiler gates, Release package/examples, and fresh LCOV. |
| `scripts/coverage ios` | Pass: 473 tests on iPhone 17 / iOS 27, Release compilation at the iOS 18 floor, lifecycle compiler gate, and fresh LCOV. |
| `scripts/coverage swiftpm linux` | Pass: 474 tests, both compiler gates, Release package/examples, and fresh LCOV in the pinned Swift 6.4 x86_64 container. |
| Focused Release tests | Pass: 23 tests across mode declarations, State lifecycle, resource startup/lifecycle/actors, and scheduler stop ordering. |

The Linux command uses the policy's exact image digest, two CPUs, 4 GB memory,
and a read-only source mount copied to an isolated writable build directory.
Apple Container's emulated launcher emits `safeExec` signal 32/33 warnings while
running examples; both examples and the canonical command exit successfully.
These are not Swift compiler warnings. All builds retain warnings-as-errors.

The new production declaration file has 23 of 23 executable lines covered in
both Apple LCOV exports. Every coverage gate uses its own fresh build directory;
ordinary or previous build products do not contribute to these reports.

## Limits

Initializer defaults deliberately permit omitted lifecycle callbacks. Types
reject incompatible supplied callbacks; they cannot prove that omission is
appropriate or that native shutdown actually joins owned work. System authors
still need runtime conformance tests. Copied native references and unstructured
tasks remain author-owned obligations.

The local Apple runs prove deployment-floor compilation and current-runtime
behavior, not execution on the oldest supported OS versions. No Location or
HTTP adapter, dependency, schema, or new native conformance is delivered here.
Hosted CI and Codecov upload are not monitored at the owner's request; required
checks and separate owner authorization still govern merge.
