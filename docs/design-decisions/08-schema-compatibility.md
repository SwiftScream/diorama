# Decision 8: Schema compatibility

- Status: Accepted
- Last updated: 2026-09-05
- Depends on: [Decision 1: Common abstraction](01-common-abstraction.md),
  [Decision 2: Shared and system-specific semantics](02-shared-vs-system-semantics.md),
  [Decision 3: Recorded behaviors](03-recorded-behaviors.md),
  [Decision 4: Replay selection](04-replay-selection.md),
  [Decision 5: Consumption and verification](05-consumption-and-verification.md),
  [Decision 6: Runtime-to-snapshot conversion](06-runtime-to-snapshot-conversion.md),
  [Decision 7: Persistence boundary](07-persistence-boundary.md)

## Decision

What compatibility and migration promises does Diorama make for persisted
scenario schemas?

## Context

Diorama scenarios are intended to be edited, reviewed, and retained in version
control. They may outlive the package version that recorded them. Re-recording
must also preserve authored overrides, making "delete every old snapshot" an
unattractive default migration strategy.

At the same time, one scenario can contain independently implemented systems.
The Diorama envelope may remain unchanged while an HTTP, location, clock, or
consumer-defined recording evolves. A single global version cannot accurately
describe both layers.

Decision 7 chose `Codable` as the sole initial track persistence mechanism, but
`Codable` by itself is not a schema policy. Synthesized representations can
change when Swift types change, older and newer enum cases need explicit
handling, and decoding an unknown key successfully does not prove that its
meaning is understood.

The schema policy must balance:

- long-lived, version-controlled fixtures;
- deterministic and readable diffs;
- deliberate evolution of first-party systems;
- independent evolution of consumer systems;
- actionable incompatibility diagnostics;
- a small initial implementation rather than a general migration framework.

## Options considered

### Use the package version as the schema version

The document could record the Diorama release that wrote it and require a
matching library release.

This couples persistence to unrelated code changes and does not express which
system payload changed. Patch releases would create noise, while two schemas
could still exist within one package version during development.

### Use one global document schema version

A single integer is simple and sufficient for a closed set of built-in values.
With pluggable systems, changing one consumer payload would either require a
global version bump or occur invisibly beneath the global version.

### Version the envelope and each system payload independently

The Diorama document has a required envelope schema version. Every persisted
system entry also declares a stable type identifier and its own payload schema
version. Each owning implementation controls decoding of its supported payload
versions.

This adds metadata but keeps responsibility aligned with the layers established
in decisions 2, 6, and 7. It is the recommended approach.

## Versioned document shape

A persisted scenario should contain at least the conceptual information shown
below:

```json
{
  "diorama": {
    "schemaVersion": 1
  },
  "systems": {
    "weather-api": {
      "type": "org.swift.diorama.http",
      "schemaVersion": 1,
      "recording": {}
    },
    "device-clock": {
      "type": "org.swift.diorama.clock",
      "schemaVersion": 1,
      "recording": {}
    }
  }
}
```

This is illustrative rather than a final field layout.

The identifiers have different roles:

| Value | Meaning |
| --- | --- |
| Attachment key | Scenario-local configured instance, such as `weather-api` or `device-clock`. |
| System type identifier | Stable owner and semantic kind of the persisted payload. |
| System schema version | Version of that type's persisted payload. |
| Diorama schema version | Version of the scenario envelope and core-owned structures. |

The package or module version may appear in transient diagnostics, but it is
not a compatibility key and should not churn canonical scenario files.

System type identifiers must be stable and collision-resistant. The exact
naming convention and registration API are deferred, but changing a Swift type
name or module layout must not silently change persisted identity.

## Version semantics

Schema versions should be positive integers, not semantic-version strings. A
version names one understood persisted shape and meaning; compatibility is
defined by explicit readers rather than inferred from major, minor, and patch
components.

An owner increments its schema version when a canonical persisted change is not
understood with the same meaning by all readers of the previous version. This
includes changes such as:

- removing or renaming a field;
- changing a field's units, normalization, or default;
- changing an enum representation or case meaning;
- changing lifecycle grouping or resource-reference semantics;
- making optional data required;
- writing a new field that strict older readers cannot accept.

A reader may become more tolerant of a known version without changing the
canonical writer. Fixing a decoder bug also need not create a new schema when
the intended persisted contract did not change.

The current writer emits only its latest canonical version. It does not offer
general downgrade writing.

## Compatibility promise

For the Diorama envelope and first-party system payloads, each release should:

- read the current schema it writes;
- continue reading every schema version previously written by a public release
  in the same major package-version series;
- convert supported older versions into the current strict semantic model;
- write only the latest canonical schema;
- reject versions it does not explicitly support.

Removing a previously supported reader is therefore a package-major breaking
change. A major release may narrow old-schema support only with a documented
migration path that can be run before or during upgrade.

Before Diorama's first public schema release, fixtures produced by this POC or
development prototypes have no compatibility guarantee. The initial clean-slate
implementation begins with an explicit version 1 rather than attempting to
infer unversioned content. No POC importer is required.

Consumer-defined systems own their payload compatibility promises. Diorama can
route a declared version to the registered system, but it cannot migrate
semantics it does not understand. The registration should advertise which
versions that system can decode so diagnostics can distinguish an unknown type
from an unsupported version.

## Migration model

Migration occurs while decoding into the current stable semantic model. It need
not be a public graph of dynamically composed migration objects. With the
initial `Codable` design, a registered system can:

- decode the current payload directly;
- decode an older version into a private legacy `Decodable` representation;
- convert that legacy value into its current stable recording type;
- validate the result before it enters scenario execution.

The top-level persistence implementation applies the same approach to older
Diorama envelope versions. Version dispatch is explicit; a decoder must not
guess a version from whichever fields happen to be present.

Migration is in-memory and read-only by default. Loading an old scenario for
replay does not rewrite the file. A successful re-recording naturally writes
the latest schema when it publishes its complete candidate. A future explicit
migration command can publish a schema-only upgrade using decision 7's atomic
publication rules.

If migration fails, the original scenario remains untouched and the diagnostic
identifies the document version, system type, system version, attachment key,
and failing migration stage where available.

## Forward compatibility

Diorama should not promise that an older reader can use a newer schema. An
unsupported newer Diorama or system version is incompatible, not an empty or
partially usable track.

This conservative rule matters because silently ignoring a new lifecycle field
could change replay behavior. It also avoids loading a newer scenario and then
rewriting it with an older writer that discards information.

Decision 7 still permits a record-only execution with no effective replay
systems to replace an incompatible baseline after clearly diagnosing the loss
of overrides and unchanged tracks. That is explicit regeneration, not forward
compatibility.

## Unknown fields

Diorama-owned envelope and first-party payload structures should reject unknown
fields by default. This catches misspelled manually edited fields and prevents
a reader from accepting data it will discard on canonical write.

An explicitly declared extension or metadata object may allow arbitrary keys,
but generic metadata is not added merely as a compatibility escape hatch.
Consumer systems define strictness within their own payloads and are responsible
for any unknown data they preserve.

Strict unknown-field validation requires deliberate `Codable` implementations
for long-lived first-party schema types. Merely declaring `CodingKeys` is not a
complete policy because standard keyed decoding can ignore keys the type does
not request.

## Initial file encoding

The initial first-party file repository should use UTF-8 JSON. This keeps the
first implementation on Foundation's `JSONEncoder` and `JSONDecoder`, avoids a
format dependency, and remains reasonably editable and well supported by
version-control tooling.

Canonical output should have:

- pretty printing;
- deterministic object-key ordering;
- semantic array order preserved exactly;
- one documented representation for each first-party enum and scalar;
- no volatile recording timestamps, package versions, process identifiers, or
  host paths unless they are part of deliberate replay semantics;
- a trailing newline and otherwise stable whitespace policy.

First-party persisted types should define deliberate `Codable` shapes rather
than allow ordinary Swift refactoring to change the document accidentally.
Golden-file tests should protect canonical output.

The persisted schema remains conceptually separate from JSON. A future
repository could use another encoding by explicitly implementing the same
semantic schema or introducing a new repository contract. Supporting multiple
text syntaxes is not an initial goal.

## Tolerant editing and canonical writing

Strict schema identity does not prevent narrowly designed tolerant input.
Decision 3 already accepts both a concise observed value and an explicit
observed-plus-override form. Such alternatives are part of the declared schema
version and decode to one strict runtime value.

The canonical writer emits only the chosen canonical form. Tolerant forms must
be documented field by field; they do not imply general coercion of strings,
numbers, enum names, or unknown structures.

This preserves manual experimentation without turning malformed data into a
different valid recording silently.

## Referenced resources

A resource reference stored by a system is part of that system's versioned
payload schema. A first-party file repository should normally encode portable
scenario-relative paths. An external absolute path may be a deliberate custom
system semantic, as accepted in decision 7, but is not a portable default.

Referenced content can be read lazily. Missing, unreadable, or structurally
invalid content produces a resource diagnostic rather than a recorded domain
failure. Changing the referenced file intentionally changes replay content; a
content digest is not required by the initial schema solely to prevent edits.

For a repository-managed multi-file publication, the manifest and resources
must still satisfy decision 7's logical atomicity. The exact directory and
resource naming layout is deferred.

## Diagnostics

Schema diagnostics must distinguish at least:

- an unversioned or malformed Diorama envelope;
- unsupported older or newer Diorama schema versions;
- unknown system type identifiers;
- unsupported system schema versions;
- malformed payloads within a known version;
- failed legacy-to-current conversion;
- unknown fields in strict structures;
- missing or invalid referenced resources.

Diagnostics should include safe coding paths and declared versions without
dumping unredacted payload values. They enter decision 5's report and optional
sink. Replay setup cannot continue when required behavior is incompatible.

## Compatibility tests

Round-trip tests are insufficient because a reader and writer can change in the
same way while remaining mutually consistent but incompatible with committed
fixtures.

Each Diorama-owned schema should have:

- canonical golden files for the current writer;
- read fixtures for every supported historical version;
- migration tests comparing old fixtures with the expected current semantic
  model;
- rejection tests for unknown versions, unknown required system types, and
  malformed structures;
- canonicalization tests for every tolerated editing form;
- resource-reference tests where a system supports external payloads.

First-party systems carry the same obligations for their payload schemas.
Consumer-defined systems can use a Diorama conformance-test helper without
making their compatibility policy a core responsibility.

## Worked examples

### Older HTTP payload

HTTP payload schema version 1 stores a response body inline. Version 2 adds an
explicit inline-or-resource representation. The registered HTTP system retains
a version 1 decoder that converts the inline bytes into the current semantic
body case. Replay does not rewrite the version 1 file; a later successful
recording writes version 2.

### Newer location payload

An older Diorama release encounters a location system payload version it does
not support. It reports the attachment key, system type, declared version, and
supported versions. It does not ignore the new fields and replay only the
locations it recognizes.

### Manual timing override

A user adds the explicit `override` form accepted by the current system schema.
The reader gives it precedence over the observed value. Canonical writing later
emits only the effective override, as accepted in decision 3.

### Consumer-defined system

A custom database system registers type `com.example.database` with payload
schema version 3 and decoders for versions 1 through 3. Diorama routes the
payload and version to that registration. The system, not Diorama core, owns the
legacy database-recording conversion.

### POC snapshot

An unversioned POC JSON exchange array is not guessed to be Diorama version 1.
It is diagnosed as unversioned. The POC and its files are exploratory inputs,
not legacy data that the clean-slate implementation must preserve or import.

## Recommendation

Require explicit, independent integer schema versions for the Diorama envelope
and every persisted system payload. Pair each system version with a stable type
identifier distinct from its scenario attachment key. Use explicit registered
readers to convert supported historical payloads into the current strict
semantic model.

Within one major Diorama package series, retain readers for every schema version
previously written by its public releases. Write only the latest canonical
schema and never rewrite during replay. Reject unsupported future versions and
unknown fields in Diorama-owned structures rather than silently discarding
data.

Use deterministic, pretty-printed UTF-8 JSON for the initial file repository,
with deliberate first-party `Codable` representations and golden compatibility
fixtures. Treat POC and other unversioned input as incompatible.

## Consequences

Benefits:

- Version-controlled scenarios survive compatible package upgrades.
- Core and system schemas evolve independently.
- Older fixtures migrate without losing authored overrides through re-recording.
- Newer or misspelled data cannot be silently ignored and rewritten.
- Deterministic JSON keeps review diffs focused.
- Consumer systems control the semantics only they understand.

Costs:

- First-party systems retain legacy decoders and golden fixtures.
- Strict unknown-field checking needs deliberate decoding support.
- Heterogeneous payload dispatch requires stable identifiers and registration.
- Older readers reject newer files rather than offering partial replay.
- Major releases need a documented strategy before dropping old readers.

## Explicit non-decisions

This proposal does not determine:

- final JSON field names or nesting;
- stable type-identifier naming syntax;
- concrete registration, version dispatch, or legacy decoder APIs;
- exact scalar encodings beyond decisions 15 and 16's initial duration, date,
  and location-measurement formats, including URLs and headers;
- multi-file resource directory and naming layout;
- whether a standalone migration command ships;
- compatibility promises made by consumer-defined systems;
- schema support retained across a future package-major boundary.

## Review questions

1. **Version boundaries: Resolved.** Every scenario declares a Diorama envelope
   schema version. Each persisted system entry independently declares a stable
   type identifier and payload schema version, while attachment keys remain
   separate scenario-local instance identifiers.
2. **Compatibility promise: Resolved.** Each major Diorama package series reads
   every schema version previously written by its public releases, converts
   older values in memory, and writes only the latest schema. First-party
   systems follow this promise; consumer-defined systems own and advertise
   their payload compatibility windows.
3. **Forward and unknown data: Resolved.** Unsupported future versions and
   unknown fields in Diorama-owned and first-party structures are rejected
   rather than ignored. Narrowly documented tolerant forms and declared
   extension areas remain allowed. Consumer systems own their payload policy,
   with strict handling recommended.
4. **Initial encoding: Resolved.** The first file repository uses
   deterministic, pretty-printed UTF-8 JSON with deliberate first-party
   `Codable` shapes and golden-file compatibility tests. JSON remains a
   repository concern rather than a core record/replay requirement.
5. **Unversioned input: Resolved.** The clean-slate implementation rejects POC
   and other unversioned files. The exploratory POC format has no compatibility
   or importer requirement.

These resolved points are the accepted answer to decision 8.

## Consistency review

The review after decision 8 found no conflict requiring an accepted decision to
be reopened.

- The authoritative scenario remains a strict semantic graph. `Codable`, JSON,
  and schema versions belong only to the optional persistence layer.
- A scenario attachment key identifies one configured instance, while a stable
  system type identifier and payload schema version select its persisted
  decoder. These roles do not overlap with decision 4's internal match keys.
- Decision 3's tolerant observed-and-override input is a declared schema form,
  so it remains compatible with strict rejection of otherwise unknown fields.
- Schema migration produces the current semantic model in memory and does not
  mutate replay fixtures or execution-local consumption state.
- Schema and resource diagnostics enter decision 5's report and optional sink;
  they do not assign a test outcome.
- An unusable baseline prevents any required replay. A record-only execution
  may replace it after diagnosis and successful whole-candidate publication, as
  accepted in decision 7.
- Referenced resources remain stable semantic references and may be resolved
  lazily; an in-memory scenario does not imply that all payload bytes are
  resident in memory.

Normalization and redaction details remain intentionally deferred to decision
9. Lifecycle ownership for loading, finalization, diagnostic delivery, and
publication remains deferred to decision 10.
