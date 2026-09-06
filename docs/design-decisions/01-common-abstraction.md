# Decision 1: Common abstraction

- Status: Accepted
- Last updated: 2026-09-05
- Depends on: None

## Question

What is the smallest common abstraction across an HTTP exchange, a location
event stream, and a test-controlled clock: an interaction, an event timeline,
dependency behavior, or several related primitives?

## Forces

The abstraction needs to support significantly different shapes of behavior
without erasing the semantics that make each integration useful.

An HTTP operation is usually initiated by a request and completes once with a
response or error. Matching a recorded request to a replayed result matters.

A location service has lifecycle operations such as start and stop, followed by
zero or more unsolicited location values and errors. Ordering and relative time
matter, while request matching alone does not describe the behavior.

A clock may be read synchronously, but useful test control also includes
suspending until a deadline and advancing logical time. Artificial advancement
is active simulation, not merely returning a recorded value.

The library should also allow one test to use several integrations without
making harmless task scheduling differences cause snapshot failures.

## Options considered

### One request/response interaction

Every operation could be modeled as an input followed by one output.

This fits basic HTTP calls and synchronous clock reads. A stream would need to
pretend that subscription returns an array, keep an interaction permanently
open, or encode each emission as a synthetic response. Those representations
lose natural subscription, timing, cancellation, and incremental delivery
semantics. A controllable clock would likewise become a collection of special
requests rather than a coherent time source.

This option is too narrow as the universal abstraction.

### One globally ordered event timeline

Every observation could become an event in one total sequence. Calls, returns,
stream values, errors, and time advancement can all be represented this way.

This is expressive at the storage level, but it is too weak as the only public
abstraction: integrations would repeatedly reconstruct correlation and domain
rules from untyped events. A mandatory global order would also make concurrent
tests brittle when two independent dependencies happen to interleave
differently.

An event record is useful infrastructure, but a single strict global timeline
should not define all runtime semantics.

### One dependency-behavior protocol

A sufficiently abstract protocol could ask each dependency to record and replay
its behavior.

This gives integrations freedom, but the common protocol would either say very
little or accumulate associated types and hooks for every behavior shape. It
would provide nominal uniformity without a useful shared semantic model.

### Shared scenario substrate with capability-specific primitives

The core can share recording infrastructure while exposing different runtime
primitives for distinct behavior shapes.

The proposed substrate is:

- A **scenario** is the record/replay context used by a test.
- A scenario contains one or more named **tracks**.
- A track is an ordered sequence of stable, integration-defined records.
- Order is guaranteed within a track. Cross-track order is not strict unless an
  integration explicitly needs coordination.
- Records may carry correlation or logical-time information, but their exact
  representation is deferred to later decisions.
- An integration interprets its tracks through a capability appropriate to its
  runtime behavior.

The initial capabilities would be conceptually distinct:

| Capability | Suitable behavior |
| --- | --- |
| Interaction | A call correlated with one returned value or thrown error, such as an HTTP request. |
| Stream | Subscription lifecycle followed by ordered values, errors, completion, or cancellation. |
| Clock | Wall-time observations plus a scheduler-backed monotonic clock and sleepers. |

These are conceptual responsibilities, not proposed Swift protocol names. Later
decisions will determine whether they become public protocols, concrete types,
adapter conventions, or a smaller set of implementation building blocks.

## Recommendation

Adopt the shared scenario substrate with capability-specific primitives.

The common abstraction should be a **scenario containing independently ordered,
typed tracks**, not a universal request/response exchange and not a single
mandatory global event sequence. Interaction, stream, and clock integrations
should share scenario lifecycle, record storage, logical-time coordination, and
diagnostics while retaining behavior-specific replay engines.

This gives the library a genuine common core without claiming that all
dependencies behave alike. It also leaves room for a future integration to add
a new capability rather than distorting itself to fit HTTP semantics.

## Worked examples

### HTTP

An HTTP integration owns an interaction track. Each invocation is correlated
with a returned response or transport error. Its replay engine may match by
request properties rather than consume only by position. HTTP-specific values
and matching policy do not belong in the scenario substrate.

### Location updates

A location integration owns a stream track containing lifecycle observations
and ordered emissions. Replay can emit locations and failures incrementally as
logical time advances. It does not need to invent a request for every emitted
location.

### Clock

A clock integration participates in the scenario's logical time. Its monotonic
facet provides logical `now` values and resumes sleepers through the shared
scheduler. Recorded wall-clock observations use an editable ISO 8601 origin
plus signed successive deltas, so changing the origin shifts the replay without
rewriting its relative progression.

Ordinary replay requires no Diorama interaction after setup and initially maps
logical time one-to-one to real time. Constant-factor acceleration is the
leading enhancement; manual advancement and fully virtual time remain future
possibilities.

### Combined test

A scenario could contain `weather-api`, `device-location`, and `clock` tracks.
Each preserves its own deterministic order. Logical timestamps can coordinate a
location emission with a timeout without requiring every independent HTTP and
location event to have one fragile total order.

## Consequences

Benefits:

- Runtime APIs can remain natural and type-safe for each behavior shape.
- Shared persistence and lifecycle work is not duplicated by each integration.
- Multiple integrations can participate in one test scenario.
- Per-track ordering supports determinism without over-constraining concurrency.
- The core vocabulary is no longer tied specifically to networking.

Costs:

- Diorama will have several concepts rather than one universal exchange type.
- Type erasure and persistence across heterogeneous tracks will require careful
  design.
- Logical-time ownership and cross-track coordination need explicit semantics.
- Integration authors must choose or define an appropriate capability.

## Explicit non-decisions

This proposal does not yet decide:

- which semantics every track must share;
- the concrete event and error representation;
- whether timing is always recorded;
- the default replay matching or consumption policy;
- whether a scenario is stored in one file or several;
- whether stable values use `Codable`;
- whether `URLSession` and `AsyncHTTPClient` share an HTTP model.

Those are covered by later decisions.

## Accepted answer

Diorama will use a scenario containing independently ordered, typed tracks as
its common substrate. Interaction, stream, and clock behavior remain distinct
capabilities above that substrate. One logical scenario may contain tracks from
several integrations.

Ordering is guaranteed within each track. Shared logical time can coordinate
tracks, but strict global interleaving is not the default. When a scenario needs
explicit cross-track coordination, it is configured during setup and enforced
automatically during replay rather than driven manually by the test. The
coordination mechanism and its initial-release scope are deferred to a later
decision.

Clock recordings represent wall time as an editable ISO 8601 origin plus signed
successive observation deltas. Replay normally operates after setup without
further Diorama API calls. Manual logical-time advancement may be offered in a
future release for tests that need precise scheduling.

First-party and consumer-defined systems can contribute tracks to the same
scenario. A scenario may therefore contain HTTP, location, clock, and custom
recordings together, independently of whether persistence eventually uses one
file or several.

## Review questions

1. **Clock intent: Resolved, revised by decisions 14 and 15.** Support recorded
   wall-clock observations as an editable ISO 8601 origin plus signed successive
   deltas. Normal replay requires no Diorama interaction after setup and maps
   logical time one-to-one to real time. Manual advancement remains future work.
2. **Scenario grouping: Resolved.** One scenario can contain tracks for HTTP,
   location, clock, and consumer-defined systems. The integration system must be
   pluggable. Persistence layout remains undecided.
3. **Cross-track ordering: Resolved.** The core preserves deterministic order
   within each track, while each capability decides which parts of that order
   replay must enforce. Shared logical time provides meaningful coordination,
   but replay does not enforce the exact global interleaving of independent
   operations by default. Explicit cross-track constraints may be configured at
   scenario setup and then run automatically; their concrete design is deferred.

## Later clarification

Decision 3 narrowed the initial playback scope to real-time automatic logical
time, mapped one-to-one to a monotonic host clock. Constant-factor acceleration,
manual advancement, and fully virtual time remain possible future enhancements,
not initial implementation requirements or configuration surfaces.

Decisions 7 and 8 resolve the persistence deferrals: the core semantic scenario
does not require `Codable`, persisted track types do, and the initial file
repository uses a versioned deterministic JSON document.
