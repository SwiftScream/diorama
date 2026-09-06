# Decision 6: Runtime-to-snapshot conversion

- Status: Accepted
- Last updated: 2026-09-05
- Depends on: [Decision 1: Common abstraction](01-common-abstraction.md),
  [Decision 2: Shared and system-specific semantics](02-shared-vs-system-semantics.md),
  [Decision 3: Recorded behaviors](03-recorded-behaviors.md),
  [Decision 4: Replay selection](04-replay-selection.md),
  [Decision 5: Consumption and verification](05-consumption-and-verification.md)

## Decision

Where does conversion between runtime-native values and stable snapshot values
occur, and which layer owns its semantics and failures?

## Context

The POC gives `URLSessionRequest` and `URLSessionResponse` custom `Codable`
implementations, but each value still wraps a Foundation runtime type. The
encoding is package-owned while the in-memory model remains coupled to
`URLRequest` and `HTTPURLResponse`.

That approach does not generalize cleanly:

- `AsyncHTTPClient` uses different request, response, body, and error types.
- `CLLocation` and its errors contain runtime details that are not all relevant
  or stable for replay.
- clock instant types may be generic, process-relative, or non-serializable;
- delegate objects, closures, tasks, channels, and event-loop state cannot be
  meaningful snapshot values;
- consumer-defined systems need a clear point at which their values become safe
  to store, match, inspect, and replay.

Decisions 2 and 3 already require adapters to convert native values into typed,
stable system or domain values. This decision makes that boundary precise
without deciding the persistence mechanism or schema promised by decisions 7
and 8.

## Three representation layers

Diorama should distinguish three representations:

| Layer | Purpose | Examples |
| --- | --- | --- |
| Native runtime | Interact faithfully with the instrumented API. | `URLRequest`, `HTTPURLResponse`, `CLLocation`, native errors, clock instants. |
| Stable semantic snapshot | Describe replayable behavior independently of one runtime object graph. | HTTP fields and body bytes, location measurements, typed failures, relative durations. |
| Persisted document | Encode stable values into an editable, versioned storage form. | A JSON or YAML schema, binary body references, version metadata. |

The scenario core and built-in capabilities operate on stable semantic values.
They do not retain native client objects in tracks. Persistence encodes and
decodes stable values but is not the mechanism that makes a native object
stable.

This distinction permits a stable type to use well-defined standard value types
such as integers, strings, `Data`, or a deliberately constrained date type. It
does not require every stable type to be made only from primitives. The system
must define the value's semantics and must not rely on private runtime encoding,
process identity, delegate state, or incidental object behavior.

The stable semantic layer is strict and valid in memory. The persisted document
may be more permissive at its editing boundary, as decision 3 permits for an
observed value accompanied by an override. Decoding normalizes that input before
the scenario core receives it.

## Boundary ownership

The concrete system integration owns the native boundary because it is the
layer that understands the runtime API. It must:

- observe native inputs, phases, outputs, and errors;
- copy the semantic data needed after the native callback returns;
- convert that data into stable system or domain values;
- reconstruct native outputs, callbacks, and errors during replay;
- diagnose native constructs that its supported snapshot model cannot
  represent.

When several adapters genuinely share protocol semantics, an optional domain
layer can provide reusable stable types and conversion helpers. An HTTP domain
could eventually share header and body modeling while `URLSession` and
`AsyncHTTPClient` retain separate native extraction and materialization code.
Decision 11 determines whether the initial HTTP integrations warrant that
shared model.

The core should not require one universal bidirectional codec protocol. Inputs,
outputs, stream emissions, failures, and lifecycle phases have different
directions and construction requirements. Systems may define small typed
converters where useful, but the core contract only requires stable values at
the track boundary.

## Record pipeline

The conceptual record flow is:

```text
native operation or callback observed
    -> reserve ordering and any behaviorally relevant timing observation
    -> detach required data from mutable or non-Sendable runtime state
    -> convert and validate a stable semantic event
    -> apply the canonicalization and redaction pipeline from decision 9
    -> append the typed stable event to the scenario track
    -> later encode the stable scenario through decision 7
```

Conversion happens at the adapter or system boundary, before a value enters the
scenario track. A native object must not be retained merely so that a store can
encode it later.

The adapter may need to accumulate native data before a semantic event is
complete. For example, a URL-loading integration can observe response metadata
before the body finishes. It may record a response phase immediately and
accumulate body chunks until a terminal response can be formed. This is still
boundary conversion rather than persistence logic.

Passthrough mode does not need to perform stable conversion because it neither
records nor replays behavior. Instrumentation may still collect minimal native
context for infrastructure diagnostics, subject to the redaction rules chosen
later.

## Ordering, observation time, and conversion time

An adapter must reserve deterministic ordering at the native observation
boundary before potentially expensive body copying, validation, or encoding.
When a capability needs timing for replay, it must also capture monotonic time
at that boundary so conversion cost does not distort the recorded delay.

Timing is not mandatory for every stable record. The adapter derives and retains
only behaviorally meaningful values such as an interaction phase delay or a
stream publication offset. A demand-driven synchronous observation may reserve
order without persisting time. The exact reservation and synchronization API is
deferred, but conversion completion order must not silently reorder two events
that were observed in the opposite order.

Native values that are mutable, reference-backed, callback-scoped, or not
`Sendable` must be detached within the isolation context in which they are
valid. Only stable, concurrency-safe values cross into the scenario machinery.

## Replay pipeline

Replay has two boundary directions:

```text
native live input
    -> convert to stable match input
    -> select and atomically claim a stable grouped recording

scheduled stable phase or conclusion
    -> materialize the native value required by the client API
    -> deliver through the native callback, async result, delegate, or clock
```

Matching operates on stable semantic inputs, using the system policies from
decision 4. It does not compare arbitrary native object identity. Fields that a
matcher ignores can still be captured when they are relevant to diagnostics,
manual editing, or faithful replay.

Stable-to-native materialization should happen as late as practical, close to
delivery. This prevents runtime resources from living in the scenario and lets
the adapter apply platform-specific construction rules. Materialization must
preserve the semantic behavior promised by that system; it need not recreate
the original object's identity or unmodeled incidental properties.

## Re-recording and overrides

Re-recording converts new live observations into the same stable semantic model
used by replay. Candidate identity from decision 4 associates the new stable
group with an existing group, after which decision 3's merge rule preserves any
authored overrides.

Overrides therefore apply to stable semantic fields, not to runtime-native
objects or serialized text fragments. A fresh observed value can be discarded
when an override exists before the canonical persisted document is written.

## Supported loss and unsupported values

A stable model can deliberately omit native details that do not affect its
declared replay surface. This is explicit semantic loss, not accidental
serialization loss. For example, an HTTP system might omit private Foundation
cache metadata while preserving status, supported protocol metadata, headers,
body, and errors needed for its documented behavior.

Each first-party system must document its supported fields and test their
conversion. It must not silently use `String(describing:)`, reflection, object
addresses, or an arbitrary error's dynamic type as a substitute for a designed
stable representation. Such descriptions can vary by platform or version and
may expose sensitive data.

An unsupported native value produces a structured conversion diagnostic. A
domain may deliberately define a typed fallback case, such as a stable generic
transport failure, but doing so is part of that domain's public replay semantics
rather than an automatic core escape hatch.

## Conversion failures while recording

Recording is observation of a live dependency. A failure to convert or append
a snapshot value should not replace a successful live response with a Diorama
error when the adapter can still preserve the native dependency behavior.

The recommended behavior is:

1. Deliver the live dependency's native behavior to the application.
2. Record a structured infrastructure diagnostic through decision 5's ledger
   and optional sink.
3. Mark the affected group, track, or recording execution as unsuitable for
   silent publication as a valid snapshot.
4. Do not invent an opaque stable value or persist a seemingly complete group.

The exact transaction and flush behavior belongs to decisions 7 and 10. The
required invariant is that conversion failure cannot quietly produce a valid-
looking but incomplete recording.

If instrumentation itself cannot safely forward the native operation, it must
surface that adapter limitation explicitly. It should not be confused with a
failure returned by the live dependency.

## Conversion failures while replaying

Failure to convert a live input for matching, validate a stable recording, or
materialize a selected native result is a Diorama infrastructure diagnostic,
not recorded dependency behavior.

Decision 5 applies:

- record the diagnostic immediately and retain it in the final report;
- use the native failure channel when one exists;
- apply the system's explicit deterministic continuation policy when it does
  not;
- never contact the live dependency as fallback;
- never return the claimed recording to the available pool.

## Configuration and determinism

Conversion configuration belongs to system setup. For the same native semantic
input and configuration, conversion should produce the same stable value. It
must not depend implicitly on locale, current wall time, nondeterministic
dictionary traversal, process identifiers, or other ambient state.

Conversion and matching configuration are related but not identical. Ignoring
`User-Agent` for HTTP matching does not necessarily mean deleting it from the
recorded request. Capture policy determines the supported semantic record;
matching policy determines which captured fields select replay behavior.

Normalization and redaction also affect stable identity, matching, diagnostics,
and persisted output. Decision 9 will define their ordering and configuration.
This decision only requires them to occur before stable values become visible
to generic scenario storage or unsafe diagnostics.

## Worked examples

### URLSession

The adapter receives a `URLRequest` and captures explicit supported request
fields into a stable request value. It does not put the `URLRequest` itself in a
track. During replay, stable response fields and body bytes are used to
construct the `HTTPURLResponse` and callbacks expected by `URLSession`.

If a streamed request body cannot be captured by the supported adapter surface,
recording reports that limitation while preserving the live request where
possible. Replay does not attempt to stringify or guess the body.

### Location updates

The location adapter copies supported measurements from each `CLLocation` while
the delegate callback is active and creates a portable `DioramaLocation` that
can preserve floor and ellipsoidal altitude. Native NSError domain, code, and
supported user information become stable error data. Replay delivers portable
locations and constructs fresh NSError values; it never persists or reuses the
original runtime objects.

### Clock

A clock system converts observed wall time into the editable ISO 8601 origin and
signed successive deltas accepted in decision 15. Process-specific monotonic
instants and sleeps remain runtime scheduling details and are not persisted as
though they were portable observations.

### Consumer-defined system

A consumer wrapping a command client can define a stable command enum and
result enum. Its adapter maps native command objects and errors at invocation
and completion. It can use the interaction capability without making either
native type `Codable` or visible to the core.

## Recommendation

Keep native runtime values inside concrete system integrations. Convert them at
the observation and delivery boundaries to and from strict, concurrency-safe,
stable semantic values. Let optional domain layers share those types and
converters where reuse is real, while the core remains unaware of native types
and does not impose one universal codec.

Keep this conversion separate from persistence encoding. Reserve order and any
required monotonic timing before conversion work, make supported semantic loss
explicit, and report unsupported values structurally. Preserve live dependency
behavior when record conversion fails, but prevent the resulting incomplete
recording from being silently published as valid. During replay, use the
diagnostic and continuation rules already established without live fallback.

## Consequences

Benefits:

- Core capabilities and stores do not depend on Foundation or client-library
  runtime objects.
- Stable values are directly matchable, diagnosable, editable, and testable.
- Multiple adapters can share real domain semantics without sharing native
  mechanics.
- Recording overhead does not contaminate observed timing.
- Unsupported data cannot silently turn into unstable or sensitive strings.

Costs:

- Every system must design and test explicit conversion code.
- Stable models may need deliberate evolution as supported native behavior
  grows.
- Some client features cannot be recorded until their semantic representation
  is designed.
- Replay reconstruction can vary by platform and requires backend integration
  tests.

## Explicit non-decisions

This proposal does not determine:

- whether stable values conform to `Codable` or use another persistence
  mechanism;
- the persisted document layout, body storage, or schema versioning;
- the concrete normalization and redaction pipeline;
- whether `URLSession` and `AsyncHTTPClient` initially share an HTTP model;
- the exact stable HTTP, location, or clock value declarations;
- the supported `URLSession` body, redirect, authentication, and metrics
  surface;
- concrete converter protocols, type erasure, or concurrency primitives;
- finalization and publication APIs after a recording diagnostic.

## Review questions

1. **Representation boundary: Resolved.** Scenario tracks contain only stable
   semantic values, never native runtime request, response, location, error,
   clock-instant, delegate, or client objects. Deliberately chosen standard
   value types may still serve as stable fields.
2. **Conversion ownership: Resolved.** Each concrete system integration owns
   native extraction and materialization and may delegate genuinely shared
   semantics to a domain layer. The core does not impose one universal
   bidirectional codec; narrower converter helpers remain possible.
3. **Observation timing and isolation: Resolved.** The adapter captures logical
   time and ordering at the native observation boundary, then detaches
   non-Sendable, mutable, or callback-scoped data before entering scenario
   machinery. Conversion latency does not alter observed timing or event order.
4. **Unsupported conversion: Resolved.** Unsupported values produce structured
   diagnostics rather than automatic string, reflection, or object-identity
   fallbacks. Any lossy stable representation is an explicit, documented, and
   tested promise made by the system or domain.
5. **Record-mode failure: Resolved.** When conversion fails but the live
   dependency can continue, the application still receives the live behavior.
   Diorama records and reports the diagnostic, marks the recording unhealthy,
   and prevents it from being silently published as valid.

These resolved points are the accepted answer to decision 6.

## Later clarification

Decisions 7 and 8 resolve the persistence questions deferred here. Stable
semantic values require no core `Codable` conformance, but every persisted track
type must be registered and `Codable`. The initial first-party repository uses
a versioned deterministic JSON document while native-to-stable conversion
remains a separate system boundary.
