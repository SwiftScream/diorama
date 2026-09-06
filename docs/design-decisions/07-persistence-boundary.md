# Decision 7: Persistence boundary

- Status: Accepted
- Last updated: 2026-09-04
- Depends on: [Decision 1: Common abstraction](01-common-abstraction.md),
  [Decision 2: Shared and system-specific semantics](02-shared-vs-system-semantics.md),
  [Decision 3: Recorded behaviors](03-recorded-behaviors.md),
  [Decision 4: Replay selection](04-replay-selection.md),
  [Decision 5: Consumption and verification](05-consumption-and-verification.md),
  [Decision 6: Runtime-to-snapshot conversion](06-runtime-to-snapshot-conversion.md)

## Decision

Is persistence a fundamental part of Diorama's record/replay core, or an
optional capability layered over an in-memory scenario model?

## Context

The POC makes storage part of every `NetworkSnapshotSession`. Its generic
`SnapshotStore` loads exchanges, appends one exchange at a time, and flushes its
current array. `JSONSnapshotStore` also requires every model request and
response to conform to `Codable`.

That shape is simple for completed HTTP exchanges, but the accepted design now
requires more:

- one scenario contains heterogeneous system tracks;
- interactions and streams accumulate phases before receiving an explicit
  conclusion at the recording horizon;
- recording and replay use strict stable semantic values rather than native
  runtime objects;
- replay consumption is execution-local and never persisted;
- re-recording merges new observations with authored overrides;
- a conversion failure must not silently publish an incomplete recording;
- consumer systems should not need a core-wide `Codable` requirement merely to
  participate in an in-memory scenario.

Persistence remains essential to Diorama as a useful snapshot-testing product.
The architectural question is whether the execution engine must itself be a
store, not whether the package should ship a good file-backed implementation.

## Options considered

### Make durable storage the live recording model

Every observed event could be appended directly to a store, and replay could
query that store as operations arrive.

This supports incremental durability and can bound memory use. It also exposes
partially assembled interactions, ties replay concurrency to I/O, makes
recording-horizon finalization harder to distinguish from a process crash, and
risks overwriting a valid snapshot after a late conversion failure.

### Require a store but let it manage an in-memory cache

This is close to the POC. The session always receives a store, while the store
may cache values and flush later.

It separates some I/O, but persistence remains a mandatory dependency of core
record/replay semantics. The store protocol still tends to absorb mutation,
grouping, merge, and lifecycle responsibilities that belong to the scenario
engine.

### Layer persistence over a stable in-memory scenario

The core can load or construct a strict semantic scenario, execute against a
working in-memory model, and optionally publish a validated result through a
persistence boundary.

This supports programmatic fixtures, focused core tests, alternate repositories,
and heterogeneous consumer systems. It also permits publication to be an
explicit transaction after grouped lifecycles and diagnostics are finalized.

This is the recommended architecture.

## Authoritative runtime model

A scenario execution owns a strict stable semantic model in memory. This model
is authoritative for:

- typed tracks and grouped lifecycle records;
- record-mode accumulators;
- replay selection and the execution-local consumption ledger;
- logical timing and authored override values;
- diagnostics and recording health;
- the candidate scenario produced by recording or re-recording.

Authoritative does not mean that every payload byte must reside in memory. A
stable system value may contain a typed resource reference that is resolved on
demand. An HTTP body, for example, can refer to a filesystem resource rather
than storing a large `Data` value in the scenario graph.

The execution engine does not call durable storage for each match, claim,
callback, or append. Replay reads an immutable loaded baseline plus its own
in-memory claim state. Recording mutates a working candidate without exposing
partial groups as a successfully published snapshot.

An execution can be created from a programmatically constructed scenario with
no persistence provider. This is useful for unit tests, generated fixtures, and
consumer systems whose stable values are not persistable. File-backed scenarios
remain the ordinary snapshot-testing workflow.

Persistence is therefore optional at the core boundary but first-party
persistence is an initial product requirement.

## Persistence responsibilities

The persistence layer should own:

- locating a scenario by a consumer-facing identity;
- distinguishing missing content from an empty valid scenario;
- reading a persisted document and its associated resources;
- decoding and validating it into the strict stable semantic model;
- encoding a finalized candidate deterministically;
- staging and atomically publishing the logical scenario;
- preserving the previous published scenario when publication fails.

It should not own:

- live event correlation or recording-horizon conclusions;
- replay matching, claims, or consumption counts;
- logical-time scheduling;
- application cancellation behavior;
- test outcome policy;
- native runtime conversion;
- domain matching semantics.

These boundaries keep I/O and format concerns out of capability behavior.

## Persistence sublayers

Persistence has at least two separable concerns:

1. **Semantic encoding** converts typed stable tracks to and from a persisted
   scenario document. In the initial implementation, persisted track values use
   deliberate `Codable` conformances and are registered by stable system type.
2. **Storage** reads and publishes the document and any referenced resources at
   a destination such as the file system, memory, a package resource, or a
   consumer-defined repository.

The exact protocols are deferred, but a conceptual orchestration boundary could
look like:

```swift
protocol ScenarioRepository: Sendable {
    func load(_ identity: ScenarioIdentity) async throws -> LoadResult
    func publish(_ candidate: StableScenario, as identity: ScenarioIdentity) async throws
}
```

This is not a proposed final Swift API. In practice, a type-erased registry of
persistable systems may sit above an untyped document or resource repository so
the storage backend does not need to know every track type.

Keeping encoding separate from storage allows one human-editable schema to use
file, in-memory, or custom I/O without making the scenario engine itself a byte
store. It also gives systems a resource-loading boundary for large values that
should not be materialized until matching or delivery needs them.

## Stable values and Codable persistence

Decision 6 separates stable semantic values from their persisted encoding. A
stable type does not need to conform to `Codable` merely to enter a scenario.

A system that wants its tracks persisted must make their stable values
`Codable`. `Codable` is the only track-encoding extension mechanism required by
the initial implementation, but it is not a core capability constraint and
need not be synthesized. A deliberate custom `init(from:)` can accept the
tolerant editing form from decision 3 while `encode(to:)` writes the canonical
form.

When a persisted scenario is loaded, its system attachment keys select the
registered persistent system type. The registry supplies type-erased access to
that type's `Codable` conformance. A missing registration, unknown track type,
or mismatch between a key and its declared type is a structured load diagnostic
rather than an ignored payload.

A programmatic in-memory scenario can contain a non-persistable consumer track.
If publication is requested, every track included in the candidate must have a
registered `Codable` stable type. The initial implementation does not need to
support silently excluding ephemeral tracks from a published scenario;
refusing publication is safer than dropping one.

A resource reference can itself be `Codable` while the referenced bytes remain
outside the encoded track value. Resource staging and lookup belong to storage,
so large bodies do not require an alternative track-encoding mechanism.

## Load behavior

Loading should preserve these distinct outcomes:

```text
loaded valid scenario
scenario not found
unreadable storage
invalid document
unsupported or incompatible schema
missing or incompatible persistent system registration
```

A missing scenario is not equivalent to a valid scenario containing no
recordings. The persistence layer retains the exact load outcome even when
execution policy permits recording to continue.

If any effective system mode requires replay, a missing or otherwise unusable
scenario prevents setup because no faithful recorded behavior can be supplied.
Replay never treats invalid data as an empty fixture or contacts a live
dependency. An empty valid scenario remains distinct; normal attachment and
track validation determines whether it can satisfy the configured replay
systems.

When no effective system mode requires replay, record mode may rebuild from any
unusable baseline. A missing scenario is the normal first-recording case. An
unreadable, invalid, incompatible, or incompletely registered baseline produces
an explicit diagnostic stating that:

- the baseline was ignored;
- authored overrides and unchanged baseline tracks cannot be preserved;
- successful finalization will atomically replace the existing destination.

This baseline diagnostic does not by itself make the new candidate unhealthy.
The existing destination remains untouched until a complete, healthy candidate
publishes. If recording or publication fails, the previous file remains in
place. This permissive replacement behavior is intended for scenarios normally
reviewed and recoverable through version control.

The exact error types, validation phases, and migration behavior belong partly
to decision 8. The persistence boundary must retain enough distinction for
those policies rather than collapsing every load problem into an empty array.

## Working candidate and recording horizon

Record mode builds a candidate scenario independently from the currently
published baseline. Native events may be appended to capability-specific
accumulators during execution, but those appends are in-memory working state,
not durable publication.

At the recording horizon:

1. Every accumulator becomes a valid grouped recording with an explicit
   conclusion, including `openAtRecordingHorizon` where appropriate.
2. When a usable baseline exists, new stable groups are associated with its
   groups for override preservation using decisions 3 and 4.
3. The candidate is normalized, redacted, and validated.
4. Recording diagnostics determine whether the candidate is healthy enough to
   publish.
5. A healthy candidate is encoded, staged, and committed as one logical
   scenario publication.

This ordering prevents a process crash or conversion error from being mistaken
for an intentionally open recorded interaction.

The exact owner and API for reaching the recording horizon belong to decision
10. This decision defines the persistence transaction it must drive.

## Replacement rather than durable append

Re-recording should produce the complete next version of each record-mode track,
not append new behavior indefinitely to its previous durable contents. Before
publication, it merges deliberately authored overrides from uniquely
corresponding baseline groups.

For a mixed-mode scenario with a valid loaded baseline:

- record-mode system tracks are replaced by their finalized new recordings,
  after override merge;
- replay-mode tracks remain the loaded stable baseline;
- passthrough tracks are not newly recorded and any loaded baseline tracks are
  preserved;
- explicitly ignored or unattached persisted tracks are preserved unless a
  separate editing operation removes them.

The result is one complete candidate scenario. Publication does not mutate one
track on disk while leaving the scenario manifest or other tracks at a
different publication state.

## Healthy publication

Decision 6 requires conversion failure to mark a recording unhealthy without
changing successfully delivered live behavior. The persistence boundary should
default to all-or-nothing publication for the logical scenario.

If any record-mode track is unhealthy, normal publication is refused and the
previous published scenario remains intact. Diagnostics identify the affected
groups and causes. A future recovery feature may write a clearly separate draft
artifact for inspection, but it must not replace the replayable scenario or
look valid accidentally.

All-or-nothing publication is intentionally stricter than publishing only the
healthy tracks. Tracks can be logically coordinated through shared time, and a
partially updated mixed scenario may represent an execution that never
occurred.

## Publication outcome and visibility

Good failure visibility is an initial requirement. Finalization should return a
structured recording report that includes a publication disposition such as:

```text
published
not requested
refused because the candidate is unhealthy
failed while encoding, staging, or committing
```

For an unsuccessful publication, the report should identify the scenario
destination, processing stage, affected system, track and group where known,
safe underlying cause, and whether the previous published scenario was
preserved. It should also summarize the unpublished candidate without requiring
it to be written over the valid snapshot.

Decision 5's diagnostic sink provides prompt notification when a runtime issue
first occurs. The final recording report aggregates those issues with
finalization, validation, encoding, and storage diagnostics. Diorama
should ship a deterministic human-readable renderer for this report rather
than expose only raw diagnostic structures. Testing integrations can opt into
recording serious publication issues through their test frameworks.

Logging is not the authoritative delivery mechanism: a consumer must be able to
inspect the structured outcome programmatically. Decision 10 will determine
the finalization API and how callers are prevented from accidentally discarding
the outcome. Decision 9 applies to every rendered value and underlying error so
diagnostics do not bypass redaction.

## Atomic publication and concurrent writers

The storage backend should stage complete encoded output and replace the
destination atomically to the extent supported by that backend. A multi-file
format may require a manifest or generation directory so readers observe one
logical publication rather than a mixture of old and new resources.

Atomic replacement prevents torn output but does not prevent lost updates. The
initial file repository accepts last-writer-wins behavior when two processes
publish the same scenario concurrently. It does not retain an expected source
revision, perform a preflight fingerprint comparison, or hold a filesystem lock
for the duration of recording.

This is an explicit tradeoff for the expected workflow, where scenario files
are normally reviewed in version control and concurrent recording of one
scenario should be uncommon. A future repository may add optimistic revision
checks, a short commit-time lock, or another conditional-publication mechanism
without changing scenario execution semantics.

## Replay and persistence

Replay loads and validates a scenario, then performs no persistence writes.
Claims, lifecycle progress, diagnostics, and verification results belong to
that execution only, as accepted in decision 5.

A read-only repository or bundled package resource is therefore sufficient for
replay. Replay should not require write permission merely because record mode
can publish through the same abstraction.

Lazy body-resource loading may be useful for large scenarios, but it must not
allow schema or decoding errors to appear as ordinary recorded failures. The
initial implementation may load all stable values eagerly; lazy payload design
is deferred until justified by real scenario sizes.

## Large recordings and staging

An in-memory semantic model does not require every encoded byte to remain in
RAM. A system can model a large value as an inline payload or a typed resource
reference and load the referenced content on demand. A file-backed repository
can stage large bodies or stream resources into an unpublished generation while
keeping semantic references in the working candidate.

For a portable published scenario, a repository will normally use
scenario-relative resource references rather than embedding machine-specific
absolute paths. A consumer-defined system may deliberately support external
filesystem paths, but it must define their lifetime, portability, and behavior
when content changes. Decision 8 will determine how referenced resources
participate in schema identity and publication integrity.

Staged resources are temporary implementation state. They become part of the
published snapshot only when the complete logical scenario commits, and failed
or abandoned staging is cleaned up by the lifecycle chosen in decision 10.

The initial implementation should favor a simple in-memory candidate and
measure before adding incremental staging.

## Worked examples

### Programmatic HTTP scenario

A unit test constructs stable HTTP interactions in memory and attaches an HTTP
system in replay mode. No file or `Codable` conformance is required. Selection,
consumption, timing, and diagnostics behave exactly as they would after loading
the same semantic scenario from persistence.

### Re-recording with an override

The published scenario contains an HTTP response delay overridden to 12 seconds.
Record mode captures a fresh 180-millisecond response. The working candidate
associates it uniquely with the baseline interaction, preserves the 12-second
override, validates the full scenario, and atomically publishes the next
scenario.

### Conversion failure

A live response contains a native value the HTTP system cannot represent. The
application receives the live response, while the candidate becomes unhealthy.
Finalization reports the conversion problem and leaves the previous scenario
untouched.

### Mixed modes

The scenario replays `device-clock` while recording `weather-api`. The loaded
clock track remains unchanged. The newly finalized HTTP track replaces its
baseline after override merge. Both appear together in one candidate and one
publication.

### Concurrent publications

Two processes record the same scenario concurrently. Each builds a valid
candidate and atomically publishes it; the later publication replaces the
earlier one. The file is never partially written, but conflict detection is not
an initial guarantee.

### Rebuilding an invalid snapshot

A pure record execution finds malformed persisted input. Diorama reports that
the baseline and its possible overrides cannot be used, records a complete new
candidate, and replaces the malformed file only after successful validation and
staging. A mixed execution requiring any replay track instead refuses setup.

## Recommendation

Make the strict in-memory semantic scenario the core record/replay model. Layer
optional persistence over it through `Codable` persistent-system registration
and a scenario-level repository. Ship first-party human-editable file
persistence as an initial product feature without making `Codable`, file I/O,
or a store mandatory for core capabilities.

Load once into an execution, build recording changes in a working candidate,
and publish only a complete, healthy, finalized scenario. Use deterministic
encoding and logical atomic replacement. Never persist replay consumption or
append partial runtime events directly to the published snapshot.

Preserve distinct load diagnostics. When replay requires a baseline, refuse an
unusable one. When no system requires replay, allow a healthy recording to
replace an unusable baseline after clearly reporting the loss of override and
track preservation.

## Consequences

Benefits:

- Core behavior can be tested and used without I/O.
- Consumer systems are not forced to make every stable type `Codable`.
- Replay has no incidental writes or store latency.
- Group finalization and override merge occur before durable publication.
- Failed recording preserves the last valid scenario.
- Version-controlled workflows can regenerate malformed or incompatible
  scenarios without a separate deletion step.
- Alternate repositories can reuse the same semantic engine.

Costs:

- Persistence requires registration and type erasure for heterogeneous
  `Codable` track types.
- A working candidate consumes memory unless later staging is introduced.
- Whole-scenario publication is more involved than appending one exchange.
- Concurrent successful publications use last-writer-wins behavior initially.
- Rebuilding an unusable baseline cannot preserve its authored overrides or
  unrecorded tracks.
- Programmatic non-persistable scenarios cannot be published until their stable
  track types adopt `Codable` and are registered.

## Explicit non-decisions

This proposal does not determine:

- the human-editable encoding format or file layout;
- schema identifiers, compatibility promises, or migrations;
- concrete repository, persistent-system registry, or type-erasure APIs;
- whether bodies are inline or external resources;
- the public scenario naming and path convention;
- the exact normalization and redaction pipeline;
- automatic versus explicit finalization and publication APIs;
- recovery artifact format for unhealthy recording candidates;
- optimistic revision checking, cross-process locking, and concurrent merge;
- lazy loading or incremental staging for large payloads.

## Review questions

1. **Layering: Resolved.** A strict in-memory semantic scenario is the
   authoritative record/replay model, with persistence optional at the core
   boundary and a first-party file implementation required for the initial
   product. The semantic graph may contain typed references to large resources
   loaded from disk or another repository on demand; authoritative does not
   require all payload bytes to remain in memory.
2. **Codable persistence: Resolved.** Stable track values have no core
   `Codable` requirement. `Codable` is the sole initial track persistence
   mechanism: every track included in a published scenario has a registered
   `Codable` stable type, while non-`Codable` systems remain available to
   programmatic in-memory scenarios.
3. **Publication unit: Resolved.** Recording and re-recording build a complete
   working candidate and publish the logical scenario atomically only after
   finalization, override merge, transformation, and validation. Runtime events
   are not appended directly to the currently published snapshot.
4. **Health and mixed modes: Resolved.** One unhealthy record-mode track blocks
   the whole scenario publication. A healthy mixed-mode publication replaces
   recorded tracks and, when a valid baseline is available, preserves replay,
   passthrough, ignored, and unattached baseline tracks. Finalization provides
   an actionable structured and human-readable publication report, while the
   previous scenario remains intact on failure.
5. **Concurrent changes: Resolved.** The initial repository uses atomic
   replacement for file integrity but accepts last-writer-wins concurrent
   publication. It does not hold a recording-duration lock or implement source
   revision checks. Conditional publication remains a future repository
   capability.
6. **Load outcomes: Resolved.** Missing, empty, unreadable, invalid,
   incompatible, and missing-registration scenarios remain distinct diagnostic
   outcomes. An unusable baseline prevents setup when any system requires
   replay. Otherwise record mode may build and atomically publish a healthy
   replacement after reporting that existing overrides and unchanged tracks
   cannot be preserved.

These resolved points are the accepted answer to decision 7.

## Later clarification

Decision 8 requires independent integer versions for the Diorama envelope and
each registered system payload, selects deterministic UTF-8 JSON for the initial
file repository, and rejects unknown first-party fields and unversioned POC
input. An incompatible baseline prevents replay but may still be replaced by a
fully healthy record-only execution under this decision's rebuild policy.
