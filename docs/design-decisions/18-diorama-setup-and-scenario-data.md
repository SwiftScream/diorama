# Decision 18: Diorama setup and immutable scenario data

- Status: Accepted
- Approved by owner: 2026-09-19
- Context: Owner discussion of the 003-C04 startup API and 003-C04A ergonomics
- Refines: [Decision 2](02-shared-vs-system-semantics.md),
  [Decision 7](07-persistence-boundary.md),
  [Decision 8](08-schema-compatibility.md), and
  [Decision 10](10-lifecycle-and-ownership.md)

## Decision

Use `Diorama` for complete reusable runtime setup and `ScenarioDefinition` for
immutable semantic scenario data. In-memory record and replay are first-class
workflows. Optional persistence loads and publishes the same definitions that
programmatic callers construct and executions produce.

This records the owner's approved design direction. The examples describe the
intended API, not implemented or compiler-verified signatures. The implementation
plan must separate the underlying model migration from the convenience API and
candidate publication work before production implementation proceeds.

## Context

The initial implementation uses `ScenarioDefinition` for both recorded content
and runtime configuration. It contains a default mode and verification policy;
its attachments also contain mode overrides. `PersistedScenario` separately
holds attachments without the surrounding execution policy. Startup combines
these objects with another list of runtime systems.

Reviewing the main user workflow exposes repeated declarations and overlapping
models. A caller should declare random, URLSession HTTP, and location systems
once, select a baseline and mode, and receive their concrete dependencies in a
scoped body. That setup should also support direct in-memory recording and
replay without manufacturing a storage backend or a persistence schema.

## Ownership

| Concept | Responsibility |
| --- | --- |
| `ScenarioDefinition` | Immutable ordered attachments, their keys and system types, and prepared recorded tracks. |
| `Diorama` | Complete reusable system declarations, live configuration and factories, default mode and per-attachment overrides, execution and verification policies, and baseline/publication configuration. |
| Execution | One run's dependencies, immutable baseline, replay claims, recording accumulators, diagnostics, lifecycle, and finalization. |
| Persistence codec and repository | Registered schema conversion and loading or publishing definitions at a destination. |

Systems define the tracks required for their operation. A definition contains
their stable data, not dependency handles, live factories, runtime modes,
verification exemptions, or repository destinations. Mode overrides move out
of `ScenarioAttachment` as well as the default mode moving out of the definition.
The storage location and diagnostic scenario identity remain setup concerns;
this decision does not add identity or path fields to the persisted document.

Each start of a reusable `Diorama` creates fresh execution state and dependencies.
Configuration must not cache a previous execution or its dependencies. Systems
remain extensible through the public consumer boundary rather than a closed
list of first-party cases.

## Immutable input and output

A definition can be constructed programmatically, decoded, or returned by a
finished execution. These are the same kind of semantic value. An execution
never mutates its starting definition. Recording uses private working state,
then constructs a new complete, validated definition at finalization.

Immutability permits deliberate fixture editing by deriving a new definition;
it does not prevent adding attachments or replacing recorded values. Replay
cursors, consumption counts, and diagnostics do not become recorded content.
Independent executions may share a definition without sharing consumption.

## Attachment membership and mixed modes

The configured systems define the complete attachment set for an execution and
its resulting definition. Every attachment has one effective mode, inherited
from the setup default or selected by its override. Tracks within one attachment
cannot select different modes.

| Configured attachment | Startup and execution | Resulting definition |
| --- | --- | --- |
| Replay | Requires compatible recorded content before activation; never accesses a live source. | Preserves its baseline recording, regardless of consumption. |
| Record | May add a new attachment or re-record an existing one. | Replaces its tracks with new recordings, applying the system's authored-override merge rules where supported. |
| Passthrough | Uses live behavior without recording new values. | Preserves any baseline recording for that configured attachment; absent content contributes its valid empty layout. |
| Absent from setup | Does not participate in execution or verification. | Is omitted. |

For example, replaying random and HTTP while recording a new location attachment
produces a definition containing the original random and HTTP recordings plus
the new location recording. Omitting HTTP from setup removes HTTP from the
result, without mutating the starting definition.

Unmatched baseline attachments remain diagnosed before being discarded. Loaded
documents still require registration, decoding, and validation of every payload
before membership reconciliation. Unknown or malformed unmatched payloads cannot
be silently skipped. An additional schema reader need not activate that system.
Ignoring a configured attachment affects verification only, not membership,
its effective mode, or persistence validation.

## Construction and loading

Provide distinct construction paths with the same execution semantics:

```swift
// Recording without a baseline or persistence.
Diorama(mode: .record, systems: random, http, location)

// An explicit immutable in-memory baseline.
Diorama(
    definition: definition,
    mode: .replay,
    systems: random, http, location
)

// A file supplies the baseline and receives healthy recording updates.
Diorama(
    file: file,
    mode: .record,
    systems: random, http, location
)
```

The initializer shapes are alternatives: a setup cannot simultaneously name a
file and a competing in-memory baseline. A custom repository construction path
can sit alongside them. Ordinary in-memory use does not require a repository.
The no-baseline form must not synthesize replay content for an effective replay
attachment; explicitly supplied valid empty content remains distinct.

Constructing file-backed setup performs no file read or publication. Every
execution loads once before activation, retains its exact load outcome, and
uses that fixed semantic baseline for the run. A subsequent execution may see
file changes or the previous run's publication. A caller wanting a fixed
baseline across runs loads a definition once and supplies it explicitly.

Decision 7's load policy remains: any required replay makes an unusable baseline
fatal before activation. Record-only setup may rebuild from missing or unusable
input, diagnosing preservation loss for nonmissing unusable input. Rebuilding
does not itself make new recording unhealthy. Startup never changes the file.
This decision does not add eager resource loading or a new resource snapshot
guarantee beyond Decisions 7 and 8.

## Primary ergonomic example

The principal design example supplies a random generator, an instrumented
`URLSession`, and the Apple location facade to one scoped body:

```swift
@MainActor
func exerciseScenario(
    file: URL,
    configuration: URLSessionConfiguration
) async throws {
    let diorama = try Diorama(
        file: file,
        mode: .replay,
        systems:
            .random(key: "random"),
            .urlSession(key: "http", configuration: configuration),
            .locationManager(key: "location")
    )

    let result = try await diorama.execute {
        random, session, locationManager in

        var random = random
        return try await exerciseApplication(
            random: &random,
            session: session,
            locationManager: locationManager
        )
    }

    inspect(result.finalization)
    let applicationResult = try result.body.get()
    // result.definition exposes a valid resulting definition when available.
}
```

`exerciseApplication` and `inspect` represent caller code. Dependency types are
`any RandomNumberGenerator & Sendable`, `URLSession`, and
`DioramaLocationManager`, in declaration order. The random dependency retains
its reference semantics when locally rebound for an `inout` call. The scope
preserves caller isolation, including the main-actor location facade.

Changing `.replay` to `.record` records live behavior and publishes a healthy
result to the same file at finalization. The HTTP setup accepts and copies the
caller's `URLSessionConfiguration`, creates an adapter-owned session, and keeps
Decision 12's configuration restrictions, including disabled caching and
background-session rejection. The location facade follows Decision 16.

Factory names, generic representation, result-property spelling, and diagnostic
identity syntax remain implementation details to verify. The example does not
authorize implementing HTTP or location early, broadening their supported
capabilities, or adding a result-builder DSL.

## One semantic model at the persistence boundary

Remove the separate public `PersistedScenario` semantic object. The codec accepts
and returns `ScenarioDefinition` directly:

```swift
let codec = JSONScenarioCodec(registry: registrations)
let bytes = try codec.encode(definition)
let restored = try codec.decode(bytes)
```

This does not require `ScenarioDefinition: Codable`. The core remains usable
with nonpersistable consumer systems. Persistence owns explicit registered
codecs, private deliberate `Codable` schema representations, version dispatch,
strict field validation, and deterministic JSON. A semantically valid definition
may still be unencodable without the required system registrations.

Ordinary file convenience should obtain the required codecs from persistent
system declarations without asking callers to declare the same systems twice.
Advanced use must retain explicit registration, including readers for baseline
attachments that will be discarded. Core-only setup must not acquire a mandatory
persistence dependency to make this convenient.

The semantic type consolidation does not itself change the version-one file
format. Existing canonical fixtures and compatibility tests remain authoritative.
Prepared decoded values continue to be validated without rerunning capture
transformations, as specified by Decision 9.

## Common results and optional publication

Both in-memory and repository-backed workflows expose:

- the scoped body's value or error;
- the immutable finalization report; and
- the resulting `ScenarioDefinition`, when a complete, healthy semantic
  definition could be constructed.

Publication is an additional reported outcome. A valid definition remains
available if encoding or storage publication fails. A missing persistence codec
does not make otherwise valid in-memory data semantically invalid. Conversely,
failed recording, grouping, merge, or semantic validation must not expose a
partial candidate as a healthy resulting definition. Startup refusal still
returns no running execution and does not invoke the body.

Body failure or cancellation alone does not invalidate the definition or
prevent configured publication. Finalization always runs and preserves the body
outcome. Replay-only execution does not write its result back merely because a
repository is configured. Repeated finish calls return the same immutable result
and publish at most once. Publication failure does not trigger an automatic retry.

The resulting definition is explicit caller-owned data, separate from safe
diagnostic rendering. Retaining it must not retain live adapters or execution
machinery. Resource-backed systems must reconcile result resource lifetimes
with abandoned staging cleanup before that capability is implemented; a result
cannot promise usable content whose only backing storage has been deleted.
The resource ownership mechanism remains work for the first resource-backed
consumer, not a new generic staging implementation here.

## Alternatives and tradeoffs

- Keeping systems on `execute(with:)` simplifies generic storage, but leaves
  `Diorama` short of a complete reusable setup. Retaining the typed system list
  supports concise repeated execution and explicit start at the cost of a more
  involved generic implementation.
- A separate public persisted scenario separates configuration from content
  today, but duplicates the semantic boundary after configuration moves out of
  `ScenarioDefinition`. Private schema representations retain version isolation
  without requiring public model conversion.
- Mandatory repositories unify the source interface, but force in-memory
  recording through an unnecessary storage abstraction. Distinct initializers
  make the common workflows explicit at the cost of several entry points.
- Direct `Codable` conformance offers familiar standard-encoder syntax, but
  hides required heterogeneous registry context and suggests that all valid
  definitions are persistable. An explicit codec makes that requirement visible.
- Loading once at setup construction pins a baseline conveniently, but makes
  reusable file setup stale after edits or recording. Loading per execution
  favors current file contents; supplying a definition provides fixed-baseline
  behavior explicitly.
- Removing unconfigured attachments makes setup authoritative but risks deleting
  content accidentally omitted from setup. Safe diagnostics and reviewable
  atomic file changes expose that consequence; omission is not preservation.

## Reconciliation and implementation boundary

Decision 10's earlier use of "scenario definition" for runtime configuration is
superseded by the ownership table above. Its modes, policies, declarations, and
publication configuration now belong to `Diorama` setup. Execution lifecycle,
rollback, quiescence, and post-finish diagnostic rules remain in force.

Decisions 7 and 10's publication-health rules now distinguish a valid semantic
definition from successful encoding and storage publication. A later persistence
failure preserves valid in-memory output without permitting a partial file
publication. Decision 8's schemas and compatibility promises remain unchanged.

This decision replaces C04A's provisional `ScenarioSetup` name and wrapper-only
scope. It also refines C05/C06 to return in-memory definitions independently of
publication. Earlier implementation evidence remains historical; acceptance of
this design does not claim those changes are implemented or tested.

Before production work, confirm the bounded review units in
[Plan 003](../plans/003-clean-slate-implementation.md#003-c04a--unified-scenario-setup-convenience):
first separate semantic data from runtime configuration and retarget the codec,
then implement typed reusable `Diorama` construction and execution, then deliver
complete in-memory results and optional publication. Future URLSession and
location examples remain design tests until their own implementation units.
