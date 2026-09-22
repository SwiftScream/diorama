# 003-B07A: Typed dependency keys and systems

- Date: 2026-09-16
- Authority: Owner-approved detailed design and explicit authorization to
  commence B07A after raising the B07 pull request, followed by completed
  implementation approval and pull request authorization on 2026-09-16.
- Status: Complete.
- Prerequisites: [B07 evidence](003-B07-random-replay-and-deterministic-failure.md),
  [DD01](../design-decisions/01-common-abstraction.md),
  [DD02](../design-decisions/02-shared-vs-system-semantics.md),
  [DD10](../design-decisions/10-lifecycle-and-ownership.md), and
  [DD13](../design-decisions/13-random-proving-system.md).

## Public contract

`DependencyKey<Dependency: Sendable>` combines the complete stable
`AttachmentID` with the dependency's compile-time type. `ScenarioExecution`
looks up that exact identity and then validates the erased runtime value. A
forged key with a wrong system identity or dependency type therefore produces
the existing safe `invalidDependencyRequest` failure, attributed to the
requested attachment.

`ScenarioSystem<Dependency: Sendable>` is immutable reusable setup. Its public
initializer accepts one `ScenarioAttachment` and one typed preparation callback,
then derives these views from the attachment's identity:

- stable attachment content for a programmatic `ScenarioDefinition`;
- a `DependencyKey<Dependency>` for typed execution lookup.

`AnyScenarioSystem(system)` explicitly erases the dependency type and stable
attachment content while retaining exact attachment identity and preparation
behavior for heterogeneous `[AnyScenarioSystem]` startup. There is no public
untyped preparation initializer. The former raw `ScenarioSystem` initializer,
intermediate `ScenarioSystemInstance` wrapper, and
`ScenarioExecution.dependency(for:as:)` are removed. Execution lookup accepts
either a dependency key or a typed system.

A system contains no preparation context, lease, activated dependency, or other
execution state. Reusing it for several starts invokes preparation and
activation independently each time.

## System migrations

`DioramaRandomSystem.instance(named:modeOverride:sourceFactory:)` replaces the
separate attachment and registration helpers. It returns
`ScenarioSystem<any RandomNumberGenerator & Sendable>` while both live
and replay generator classes remain private. The source factory remains lazy,
fresh per live execution, and unreachable in replay.

The external `DioramaConsumerTestSupport` module now exposes an instance factory
for its concrete `ConsumerSequentialDependency`. It uses only ordinary public
`DioramaCore` imports, proving that consumer systems can construct typed systems
and erase them with `AnyScenarioSystem(system)` without SPI or `@testable`.

## Verification

- `swift test -Xswiftc -warnings-as-errors` passes all 62 current tests across
  the core, random, and external consumer modules.
- Existing and refined tests cover heterogeneous dependency types, repeated
  typed systems, both lookup forms, exact attachment identity, forged
  wrong-system and wrong-type keys, closed lookup, reusable systems with
  fresh state, random protocol-composition dependencies, shared cursors, and
  concurrent random calls.
- The external consumer target compiles with ordinary imports and derives its
  attachment, erased startup form, and typed key from one attachment identity.
- `scripts/check` passes canonical formatting, strict lint with zero violations,
  all 62 tests with warnings as errors, and release compilation.
- `scripts/coverage swiftpm macos` passes all 62 tests, its warnings-as-errors
  release build, and coverage export for every test executable.
- `scripts/coverage ios` passes the release build and all 62 tests on the iPhone
  17 / iOS 27.0 simulator while compiling at the iOS 18 deployment floor. Its
  result bundle contains coverage and no test failures.
- A native Linux run remains a hosted gate. Attempting the Linux-labeled export
  on macOS passed its tests and release build but correctly could not invoke the
  bare Linux `llvm-cov` executable; that host attempt is not Linux evidence.
- The complete branch diff and Markdown targets pass `git diff --check`.

No persistence/setup convenience, result builder, HTTP or location protocol,
lifecycle change, random behavior change, compatibility overload, unsafe
sendability annotation, or third-party dependency is introduced.

## Review handoff

Owner review approved the public naming and type-erasure refinements, including
`ScenarioSystem`, `AnyScenarioSystem`, `PreparedSystem`, `AnyPreparedSystem`,
`ActivatedSystem`, and `AnyActivatedSystem`. Required hosted Quality, macOS,
iOS, Linux, and Codecov checks pass for the merge revision.
