# 003-C04B: Reusable typed Diorama setup

- Scope confirmed: 2026-09-19
- Implementation authorized and initially completed: 2026-09-20
- Review refinements authorized: 2026-09-20 and 2026-09-21
- Revised implementation verified: 2026-09-21
- Owning unit: [003-C04B](../plans/003-clean-slate-implementation.md#003-c04b--reusable-typed-diorama-setup)
- Governing design: [Decision 18 and its amendment](../design-decisions/18-diorama-setup-and-scenario-data.md#system-type-capabilities-and-unknown-payloads--2026-09-20)

## Delivered boundary

`Diorama<each Dependency: Sendable>` lives in the consumer-facing `Diorama`
module and stores a heterogeneous tuple of
`ScenarioSystem<each Dependency>` values. Each instance refers to a shared
`ScenarioSystemType`, which owns its `SystemTypeID` and optional
`ScenarioSystemPersistence` capability. The descriptor is immutable runtime
metadata; attachment data retains only stable identity and prepared tracks.
The same ordinary system instances serve in-memory and file-backed workflows.

System construction validates that the descriptor owns the attachment identity.
Diorama construction validates unique attachment keys, then
derives the empty active layout. It performs no preparation, activation, I/O, or
publication. Each `execute` starts a fresh internal run, injects typed
dependencies in declaration order, and returns the successful body value
alongside completed finalization. Startup errors throw before the body; body
errors are rethrown after finalization. The stored parameter-pack closure retains explicit
`@isolated(any)` isolation.

Existing prepare-all-before-activation, rollback, lease closure, and idempotent
finalization semantics are shared with low-level APIs. Body failure and
cancellation still await cleanup. No run or
activated dependency is cached in setup.

The heterogeneous proof combines first-party random with separately keyed
instances of the public consumer system, whose values are not `Codable`.
Core-only tests also provide a persistence capability using just core and Swift
standard-library protocols, proving that defining a capability does not require
a dependency on the persistence module or cause in-memory execution to use it.

## Construction and use

```swift
import Diorama
import DioramaRandom
import Foundation

let random = try DioramaRandomSystem.instance(for: randomKey)

let setup = try Diorama(scenarioID: "example", mode: .record, systems: random)
let result = try await setup.execute { generator in
    var generator = generator
    return generator.next()
}
inspect(result.finalization)
let value = result.body

// The same declaration carries its type's ordinary codec automatically.
let fileURL = URL(fileURLWithPath: "/absolute/path/to/scenario.json")
let fileSetup = try Diorama(
    file: fileURL, scenarioID: "example", mode: .record, systems: random)
```

| Initializer | Baseline behavior |
| --- | --- |
| `Diorama(scenarioID:mode:systems:)` | No baseline; record/passthrough use empty layouts, effective replay refuses startup. |
| `Diorama(definition:scenarioID:mode:systems:)` | Fixed immutable definition; every run gets fresh cursors. |
| `Diorama(file:scenarioID:mode:systems:)` | Lazy file read once per start; codecs come from the configured system types. |
| `Diorama(repository:scenarioID:mode:systems:)` | Caller-configured JSON repository, including custom document storage; one load per start. |

The shared baseline resolver treats explicit or loaded content as authoritative.
Content on system declarations supplies no fallback. Missing replay attachments
refuse startup; compatible explicitly empty content remains valid. Newly recorded
attachments receive empty typed layouts. Unmatched attachments are diagnosed
and omitted; active execution follows declaration order.

## Module ownership and one consumer workflow

`Diorama` depends on core and persistence. It owns every setup constructor,
baseline reconciliation, repository-backed startup, scoped execution, and the
consumer run/result API. The core execution engine retains preparation,
activation, lease lifetime, and idempotent finalization. Persistence retains
schema dispatch, loading, encoding, and storage, with no execution-start method.

`DioramaRun` is internal and holds the engine and a concrete
`ScenarioLoadResult?` until scoped execution finishes. The public
`DioramaResult` combines the successful body value, core finalization, and that same typed
load outcome. The erased evidence field, downcasts, `RepositoryScenarioExecution`,
`ScopedExecutionResult`, and `ScenarioDefinition.execute` are removed.
The consumer operation has no diagnostic sink argument; live notifications
remain available through the lower-level core API.

The consumer module has no public type aliases. Setup takes a string scenario ID and
default mode directly; file-backed setup accepts an absolute local file URL and
converts it to a validated persistence location. Other core and persistence
types remain in public signatures and can be passed or inspected through type
inference; callers who explicitly name or construct them import their owning
module. No whole-module re-export or concurrency exception is needed. The
heterogeneous consumer test imports `Diorama`, the system modules, and test
support without importing core; it passes their returned systems directly to
setup and constructs IDs and keys contextually. Core tests and the
consumer-provided system implementation still depend only on core.
A separate local typecheck confirms that `import Diorama` cannot name
`ScenarioSystemType` without a core import.

The separate example package explicitly imports core to prepare an in-memory
replay definition using track values. This illustrates where advanced semantic
construction crosses the boundary. Custom codec and storage setup can import
persistence directly.

The current review refinement moves mode overrides and unused-replay-record
waivers to each `ScenarioSystem`. A system without
an override inherits the scenario default. Callers select an override using
`withMode(_:)`, which returns a copy; system factories decide whether to expose
the unused-record waiver. Finalized attachment usage reports that waiver as
`allowsUnusedReplayRecords`. No key-based policy can refer to an absent attachment.
The scenario ID and default mode are direct setup arguments, so
`ScenarioConfiguration` is removed from core and consumer APIs.
The consumer initializer labels that mode `mode`; internal startup retains
`defaultMode` to describe inheritance when a system has no override.

All repository startup tests use the public consumer setup. The new
`DioramaTests` target owns scoped behavior, actor isolation, cancellation,
baseline policy, independent runs, and concurrent repeated finish coverage.
Storage/schema tests retain their focused persistence coverage.

Publication orchestration belongs to this consumer layer when C05 implements
it. This review change introduces no publication behavior or placeholder result
fields.

## Optional system-wide persistence

`ScenarioSystemPersistence` lives in core and describes versioned payload
encoding and decoding through Swift's `Encoder` and `Decoder` protocols.
`PersistentSystemRegistration` implements that capability using deliberate
`Codable` schemas and explicit historical readers. The capability no longer
duplicates the owning system ID; decode receives the expected attachment identity.
The descriptor supplies ownership when a registry collects capabilities.

Reuse a descriptor across keyed instances. `ScenarioSystemType` is an immutable
reference type so the registry can recognize shared declarations and reject
distinct descriptors claiming one stable ID. Reference identity is used only
for configuration conflict detection, never stable identity, ordering, or
persistence. Historical readers are configured on the capability before creating
the shared descriptor.

There is no `ScenarioSystemDeclaration`, `PersistentScenarioSystem`, separate
persistent random factory, or additional registration list on file setup.
Consumers without persistence provide a descriptor with a nil capability.
In-memory execution never invokes codecs. File construction rejects missing
capabilities and conflicting descriptors before storage access.

## One decoder with registry-based policy

Standalone `JSONScenarioCodec.decode` and `JSONScenarioRepository.load` remain
strict: every encountered system type must have a registered codec. Execution
startup uses the same envelope decoder with an internal policy to discard
unregistered types. No configured attachment-ID filter enters the codec.

| Document entry | Execution startup |
| --- | --- |
| Registered system type | Decode and validate every instance, including inactive keys. |
| Unregistered type at an inactive key | Skip payload interpretation, retain its header, diagnose omission. |
| Unregistered type at an active key | Treat the baseline as incompatible; required replay refuses activation, record-only setup may rebuild. |
| Registered type with unsupported version or invalid payload | Preserve the existing incompatible/invalid load policy, including for inactive keys. |
| Missing required replay attachment | Refuse startup; skipped content cannot satisfy replay. |

Both policies validate the envelope, entry fields, version representation, JSON
syntax, and uniqueness of attachment keys across all entries. Unknown payloads
can have future schema versions and uninterpreted shapes, but skipping cannot
hide duplicate keys, missing payload fields, malformed headers, or malformed
JSON. Decoded definitions contain only strict semantic attachments; no opaque
payload object or raw bytes enter the semantic model.

Successful `ScenarioLoadResult.loaded` retains the decoded definition and an
ordered `skippedSystems` descriptor list. Strict loads have an empty list.
The internal run and public `DioramaResult` directly store that concrete optional
outcome. In-memory setup reports nil. Failures retain the existing
repository startup evidence. Invalid declarations fail at construction before
repository access. Diagnostics and finalization preserve engine behavior, with
the intentional unknown-type policy change recorded by the amendment.

## Verification

The final scoped-only consumer worktree passes `scripts/check`,
`scripts/coverage ios`, and the pinned Linux `scripts/coverage swiftpm linux`
on 2026-09-22. Each platform passes 179 tests; release builds and the example
build pass. An earlier revision passed `scripts/coverage swiftpm macos`.

The preceding consumer-module revision passed 179 tests in 35 suites on macOS, iOS
Simulator, and Linux. The review refinement adds targeted coverage for
core-only optional capabilities, shared metadata, strict versus tolerant decoding,
opaque future payloads, known inactive validation, header collisions, malformed
documents, active-key type mismatches, and missing replay content. The consumer
module refinement preserves the actor-isolation, typed-error, cancellation, and
cleanup tests through the single public setup API. Core tests verify concurrent
finalization through copied executions, closed dependency access, and post-finish
diagnostics. Consumer tests verify scoped cleanup.

| Check | Result |
| --- | --- |
| `scripts/check` | Pass: canonical formatting/linting, strict builds, tests, and release example build. |
| `scripts/coverage swiftpm macos` | Pass on an earlier revision: all 179 tests, debug/release builds, and LCOV export. |
| `scripts/coverage ios` | Pass: all 179 tests on iPhone 17 / iOS 27 Simulator and LCOV export. |
| Pinned Linux container running `scripts/coverage swiftpm linux` | Pass: all 179 tests, debug/release builds, release example build, and LCOV export. |
| Release `DioramaRandomUsage` example | Pass: recorded and replayed values match. |
| `scripts/verify-apple-toolchain` | Pass: Xcode 27.0 (`27A266a`), Apple Swift 6.4. |

Earlier macOS and iOS coverage runs each cover 2,321 of 2,369 source lines
(97.97%) in their canonical LCOV summaries. Intersecting executable source lines with the consumer
module revision's additions covers 39 of 42 lines (92.86%); the three uncovered
lines are the unreachable configured-dependency invariant failure. These local
measurements are separate from hosted Codecov's PR comparison.
The later review refinements change setup arguments, system policy, and the
public run surface; the earlier coverage figures do not measure these changes.
The separate consumer
test target confirms that returned system instances work with `import Diorama`
and the chosen system modules alone.

Linux uses the x86_64 Swift 6.4 image pinned in the quality policy at
`swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`.
Its source mount is read-only; compilation and coverage export run in a temporary
container workspace. The successful export is recorded in the gate log; the LCOV
file is not retained after removing that local container.

## Review boundaries

The final C04B implementation is one commit on `003-c04b-typed-diorama-setup`,
stacked on the two focused C04A commits in `003-c04a-diorama-design`. Review
fixups are consolidated into the final tree. Earlier macOS coverage measurements
predate the later consumer API refinements; final macOS, iOS, and Linux gate
results are recorded above.

No third-party dependency, persisted schema version, deployment floor, or
concurrency exception changes. Candidate extraction, resulting definitions, and
automatic publication remain C05. The example constructs a replay baseline from
observed values. File-backed execution never publishes in C04B, including record
mode and scoped body failure. Repository I/O remains synchronous.
