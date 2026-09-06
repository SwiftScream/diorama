# Decision 2: Shared and system-specific semantics

- Status: Accepted
- Last updated: 2026-09-04
- Depends on: [Decision 1: Common abstraction](01-common-abstraction.md)

## Decision

Which semantics must be common to every Diorama scenario and which should
remain specific to a behavior capability, protocol domain, or concrete client?

## Context

Decision 1 established a scenario containing typed tracks, interpreted through
interaction, stream, clock, or consumer-defined behavior. It also established
that first-party and consumer-defined systems can contribute recordings to the
same scenario.

Those systems need meaningful common guarantees. Without them, every plug-in
would invent its own mode handling, lifecycle, ordering, time, errors, and
diagnostics. However, moving HTTP matching, location subscription rules, or
`URLSession` interception into the core would make the shared abstraction
depend on concerns it cannot understand correctly.

The desired user experience is setup-oriented. After a scenario and its systems
are configured, tests should ordinarily interact only with native or injected
dependencies. Diorama-specific runtime controls are opt-in.

## Terms

For this decision, a **system** is a pluggable participant that attaches one or
more tracks to a scenario and knows how to record and replay their behavior. An
HTTP integration, location service, clock, or consumer-defined dependency can
all be systems.

A system may be assembled from narrower reusable layers:

```text
Scenario core
    |
    +-- System extension boundary
            |
            +-- Capability semantics: interaction, stream, clock, or custom
            +-- Optional protocol-domain model and policies
            +-- One or more concrete client adapters
```

These are semantic ownership boundaries. This decision does not require each
box to become a separate Swift module, protocol, or public type.

## Options considered

### Put uniform behavior in the core

The core could define one record shape, matching algorithm, replay cursor, and
timing model for all systems.

This would make first-party integrations superficially consistent, but stream
and clock behavior would be distorted around interaction semantics. Custom
systems would need to encode their behavior into core concepts or request new
core switches.

### Give systems complete autonomy

The core could be little more than a container while every system defines its
own modes, track behavior, timing, persistence hooks, and errors.

This maximizes freedom but provides too little value. Combining systems would
produce inconsistent setup and diagnostics, and third-party authors would need
to rebuild record/replay infrastructure.

### Share invariants and reuse behavior-specific layers

The core can own universal scenario invariants and a public system extension
contract. Reusable capabilities can implement common behavior shapes, optional
domain layers can own protocol meaning, and adapters can remain honest about
native-client constraints.

This option provides concrete reuse without turning current first-party
capabilities into a closed taxonomy.

## Proposed ownership

### Scenario core

The core should own only semantics that every system must honor:

- scenario identity and lifecycle boundaries;
- a common mode vocabulary with a scenario-level default;
- registration and namespacing of systems and their named tracks;
- deterministic record order and atomic mutation within each track;
- coexistence of heterogeneous first-party and consumer-defined tracks;
- shared logical time and setup-time cross-track coordination mechanisms;
- common infrastructure failures, such as missing, duplicate, corrupt, or
  incompatible tracks;
- aggregation of structured diagnostics and verification results;
- a public extension boundary through which systems attach behavior.

The common modes have these minimum meanings:

| Mode | Required meaning |
| --- | --- |
| Record | Observe live dependency behavior and contribute records to the scenario. |
| Replay | Supply behavior only from scenario records and never access the live dependency. |
| Passthrough | Use the live dependency without reading or changing recorded behavior. |

Systems may have setup policies such as matching style, playback speed, or
manual clock control. Those are not additional core modes.

The exact lifecycle API, persistence behavior, and verification rules belong to
later decisions.

### System extension boundary

The core extension contract should let a first-party or consumer-defined system:

- declare its stable identity and the tracks it owns;
- receive its effective mode and scenario services during setup;
- record and read its typed track content through core mechanisms;
- participate in logical time and configured coordination when needed;
- contribute structured diagnostics and final verification;
- release interception or runtime resources during finalization.

The core can enforce track mutation and lifecycle invariants. A system remains
responsible for faithfully applying the effective mode to its native dependency.
A future conformance test kit can help third-party implementations prove that
behavior.

### Capability semantics

Capabilities own reusable rules for a shape of behavior:

| Capability | Owned semantics |
| --- | --- |
| Interaction | Invocation/outcome correlation, returned values versus thrown errors, replay selection hooks, and interaction verification. |
| Stream | Subscription lifecycle, ordered emissions, failure and completion, cancellation, and replay scheduling. |
| Clock | Wall-time observations and a scheduler-backed monotonic clock with sleepers and cancellation. |

First-party and third-party systems should be able to reuse these capabilities.
They should also be able to implement a genuinely different behavior shape
through the system extension boundary rather than forcing it into one of the
initial three.

### Optional protocol-domain semantics

A protocol-domain layer should own semantics that are independent of a specific
client implementation:

- stable domain requests, responses, events, and errors;
- domain-specific equivalence, normalization, and validation;
- meaningful diff and mismatch diagnostics;
- domain-aware redaction policies;
- behavior shared by multiple adapters for the same protocol.

HTTP could provide such a layer for `URLSession` and `AsyncHTTPClient`, but
decision 11 will determine whether it should. This decision establishes where a
shared HTTP model would belong, not whether it must exist.

### Concrete client adapter

An adapter should own behavior tied to a runtime API:

- transparent interception, explicit wrapping, delegation, or injection;
- conversion between native values and stable system records;
- native task, callback, stream, event-loop, and cancellation mechanics;
- preserving relevant client configuration and execution context;
- detecting unsupported operations and adding native diagnostic context;
- installing and removing interception state.

For example, `URLProtocol` routing belongs only to a `URLSession` adapter. An
`AsyncHTTPClient` facade belongs only to that client adapter.

## Placement rule

A semantic rule should live in the most reusable layer that has enough domain
knowledge to define it correctly:

- Track ordering and namespacing require no payload knowledge, so they belong in
  the core.
- Call/outcome correlation belongs to the interaction capability.
- HTTP request equivalence belongs to an HTTP domain or HTTP system policy.
- `URLSessionConfiguration.protocolClasses` manipulation belongs to the
  `URLSession` adapter.

The core may provide general mechanisms for policies, diagnostics, redaction,
and time without choosing domain-specific policy values.

## Worked examples

### URLSession HTTP

The core supplies the scenario, effective mode, named tracks, ordering, and
diagnostic collection. Interaction machinery correlates requests and outcomes.
An HTTP domain, if adopted, defines stable HTTP values and equivalence. The
`URLSession` adapter performs `URLProtocol` interception and Foundation
conversion.

### Location updates

The core supplies mode, tracks, and logical time. Stream machinery handles
subscription and emission behavior. Location-specific policy defines stable
locations and errors. A Core Location adapter bridges delegates or async
sequences.

### Clock

The core supplies scenario logical time and scheduling. Clock machinery replays
wall time from an ISO 8601 origin and signed successive observation deltas; its
separate monotonic facet manages sleepers through the scheduler. A live-clock
adapter captures wall observations during recording. Manual advancement remains
a possible future setup-time control rather than a different core mode.

### Consumer-defined system

A consumer can register a system beside the first-party systems. It may reuse
interaction or stream machinery, or implement a different replay engine through
the same core extension boundary. Its tracks receive the same lifecycle,
namespacing, ordering, time access, and diagnostic infrastructure.

## Recommendation

Adopt the layered ownership model:

1. The scenario core owns universal invariants, coordination, and the system
   extension contract.
2. Interaction, stream, and clock provide reusable but non-exclusive behavior
   semantics.
3. Optional domain layers own client-independent protocol meaning.
4. Concrete adapters own native runtime integration.

Provide a consistent setup, mode vocabulary, and diagnostic experience across
systems without requiring their native runtime APIs to look alike.

## Consequences

Benefits:

- Core behavior remains small enough to specify and test rigorously.
- First-party and consumer systems share meaningful infrastructure.
- Common capabilities reduce duplication without becoming a closed hierarchy.
- Client integrations remain honest about their native constraints.
- Domain models can be reused without contaminating the universal core.

Costs:

- A feature may cross multiple ownership boundaries.
- The public system extension contract becomes an important compatibility
  surface.
- Custom behavior engines require more expertise than using a built-in
  capability.
- Reviews must prevent policy from drifting into the wrong layer.

## Explicit non-decisions

This proposal does not determine:

- concrete Swift module or package boundaries;
- record, error, correlation, or timing representations;
- replay selection and consumption policies;
- persistence format or schema compatibility;
- whether HTTP has a shared transport-neutral model;
- the supported `URLSession` feature surface.

## Review questions

1. **Ownership layers: Resolved.** The scenario core, reusable capabilities,
   optional protocol domains, and native client adapters own progressively more
   specific semantics.
2. **Mode granularity: Resolved.** A scenario has a default mode with explicit
   setup-time overrides per system. One motivating case is replaying wall-clock
   observations while recording network behavior. Overrides apply to systems by
   default rather than arbitrary individual tracks owned by a system.
3. **Custom behavior shapes: Resolved.** Consumer systems may eventually define
   behavior outside interaction, stream, and clock. The architecture must not
   make the initial capabilities a closed hierarchy, but a fully custom behavior
   engine extension API may be deferred if it requires meaningful initial
   implementation effort.

## Accepted answer

Diorama uses layered semantic ownership:

1. The scenario core owns universal invariants, coordination, diagnostics, and
   system extension mechanics.
2. Interaction, stream, and clock own reusable but non-exclusive behavior
   semantics.
3. Optional protocol-domain layers own meaning shared independently of a
   concrete client.
4. Concrete adapters own interception and other native runtime behavior.

A scenario supplies a default mode, and setup may override that mode for an
entire system. This allows coherent mixed scenarios such as replaying the clock
while recording network traffic.

First-party and consumer-defined systems can contribute tracks. Consumer
systems may use the built-in capabilities or, eventually, define another
behavior shape. Support for custom behavior engines may be implemented after the
initial capabilities, but the core design must leave a viable extension path.

## Later clarification

Decision 4 established that replay never contacts a live dependency. This
replaces the earlier proposed allowance for an explicit live fallback policy;
no fallback mechanism belongs in replay mode.

Decision 5 established that core verification produces structured replay facts
without assigning an overall test outcome. Consumers opt into evaluation
helpers or diagnostic sinks, including optional testing-framework integrations.
