# Decision 13: Random proving system and extension boundary

- Status: Accepted
- Last updated: 2026-09-05
- Depends on: [Decision 1: Common abstraction](01-common-abstraction.md),
  [Decision 2: Shared and system-specific semantics](02-shared-vs-system-semantics.md),
  [Decision 3: Recorded behaviors](03-recorded-behaviors.md),
  [Decision 5: Consumption and verification](05-consumption-and-verification.md),
  [Decision 6: Runtime-to-snapshot conversion](06-runtime-to-snapshot-conversion.md),
  [Decision 7: Persistence boundary](07-persistence-boundary.md), and
  [Decision 10: Lifecycle and ownership](10-lifecycle-and-ownership.md)

## Decision

Should a random-number provider be Diorama's first end-to-end system, what
behavior should it record and replay, and which public extension primitives
must it prove for consumer-defined systems?

## Context

The first vertical slice needs to exercise real Diorama infrastructure without
making that infrastructure inseparable from URLSession interception, HTTP
matching, stream scheduling, or platform frameworks. Randomness is a useful
test dependency with a small native contract: a generator supplies one
nonthrowing `UInt64` value at a time.

A random system can prove:

- named system attachment and independent typed tracks;
- record, replay, and passthrough mode behavior;
- stable native-to-record conversion;
- atomic ordered consumption;
- optional `Codable` persistence;
- structured diagnostics and nonthrowing failure policy;
- unused-record reporting and scenario finalization;
- the public consumer-system extension boundary.

It does not require matching, asynchronous delivery, or a logical-time
scheduler. This keeps the first implementation slice narrow without making it
throwaway work.

## Stable behavior

The system records the raw result of each `RandomNumberGenerator.next()` call
as an ordered `UInt64` value. Higher-level standard-library operations such as
integer or collection selection derive their behavior from those raw values;
Diorama does not invent separate persisted cases for ranges or result types.

Conceptually, one track contains:

```text
values:
  - 147391284918
  - 925
  - 18446744073709551615
```

The enclosing typed track supplies stable sequence. The persisted encoding may
derive that sequence from array order rather than repeat sequence numbers, as
long as the decoded semantic model preserves the same order.

Random observations do not carry timestamps. `next()` is a demand-driven,
synchronous operation with no replayable duration. This application of the
revised decision 3 rule is deliberate: timing belongs only to behavior for
which elapsed time changes replay.

## Native API

Diorama supplies a reference-semantic generator conforming to Swift's standard
`RandomNumberGenerator` protocol. Application code can therefore continue to
use APIs that accept an injected generator rather than adopting Diorama-specific
range or distribution methods.

Scenario setup attaches the random system under a caller-provided name and
returns its generator. Any number of random systems may be attached to one
scenario. Each attachment has its own generator identity, track, source, and
replay cursor. This supports independent random domains and gives concurrent
work separate deterministic sequences when the consumer configures separate
attachments.

References to the same returned generator share one cursor. Passing the
generator through application dependencies must not clone or rewind replay
state. Reference semantics make that shared attachment identity explicit.

## Live source

Recording and passthrough delegate to an injected `RandomNumberGenerator`.
Setup defaults to `SystemRandomNumberGenerator`, while accepting another source
allows consumers to select their live randomness and lets Diorama test recording
with a known sequence.

The attachment owns and serializes access to its source. Replay neither
initializes nor consults that source. A missing recording can never fall back to
a fresh random value.

## Mode behavior

| Mode | `next()` behavior |
| --- | --- |
| Record | Atomically obtain the next live value, append it to the attachment track, and return it. |
| Replay | Atomically consume and return the next recorded value without touching the live source. |
| Passthrough | Obtain and return the next live value without reading or changing the track. |

The source call and corresponding track mutation in record mode form one
serialized attachment operation. This prevents two callers from associating
record order with the opposite returned values.

Re-recording replaces the generated track content for that attachment rather
than appending a new run to the previous sequence. Random values have no initial
authored-override fields; an intentionally fixed sequence is represented by
editing or supplying the ordinary recorded values.

## Concurrency and multiple attachments

Calls against one attachment are memory-safe and acquire a single atomic order.
When several tasks call the same generator concurrently, the caller that
acquires the attachment first receives the next value. Diorama does not record
task identity or attempt to reproduce which racing task wins in another run.

A test that needs a stable mapping between concurrent domains should coordinate
those calls in application code or attach separate named random systems. Separate
attachments never share sources, tracks, locks, or cursors unless the consumer
deliberately supplies a shared live source whose own semantics permit it.

The implementation must satisfy the accepted strict-concurrency policy. Any
internal lock-backed sendability assertion documents its synchronization
invariant and receives focused concurrent-consumption tests.

## Replay exhaustion

`RandomNumberGenerator.next()` cannot throw, so replay exhaustion cannot be
reported through its return type. When no recorded value remains, Diorama:

1. creates a serious structured diagnostic containing the scenario, attachment,
   track, requested position, and available count;
2. submits it to the scenario's configured diagnostic handler;
3. returns `0` if that handler returns;
4. never obtains a replacement value from the live source.

The zero is a deterministic continuation value, not a successful recovery.
Test setup may select the accepted trap-on-serious-error handler when immediate
termination is preferable. A reporting handler may instead fail the surrounding
test and return, in which case the total nonthrowing API still has defined
behavior and avoids nondeterministic cascades.

Calls made after the attachment or scenario has finalized follow the same
diagnostic-and-deterministic-continuation principle with a distinct lifecycle
diagnostic.

## Finalization

The core marks every successfully returned replay value as consumed. At
finalization it reports remaining random values as unused recordings through
the common verification report. Diorama does not directly fail the test; the
consumer's selected evaluation helper or diagnostic integration decides how
unused values affect that test.

Random has no open interaction to drain. Finalization closes the generator to
new valid operations and releases its source and track lease according to
decision 10.

## Public extension boundary

The first implementation must expose enough public, typed infrastructure for a
consumer-defined synchronous system to:

- declare a stable system identity and record type;
- attach one or more instances under caller-provided names;
- receive the effective mode and a typed track lease;
- append records atomically in record mode;
- consume the next record atomically in replay mode;
- emit structured diagnostics;
- participate in finalization and unused-record reporting;
- register `Codable` persistence for a persistable record type.

A stable record type need not be `Codable` when the scenario uses only in-memory
storage. If publication is requested, decision 7 requires the system to provide
its deliberate `Codable` representation.

The first-party random system must use only this public boundary. It must not
reach through internal scenario storage or receive privileged mode and
diagnostic hooks. A test-only consumer-defined system must implement the same
path from another module, proving that access control and generic constraints
work for consumers rather than only inside the Diorama package.

The initial boundary is intentionally a low-level sequential-track primitive.
Later interaction, stream, matching, and scheduling helpers can build on it.
They should not be anticipated as optional methods on one large system protocol
or block this first vertical slice.

## Implementation progression

Decision 13 defines a milestone, not one large change. The clean-slate plan
should separate at least these reviewable slices:

1. typed system identity, attachment name, mode, and in-memory sequential track;
2. public record and replay lease operations with atomic consumption;
3. external-module consumer-system conformance test;
4. random generator record and passthrough behavior with an injected source;
5. random replay, exhaustion diagnostics, and deterministic continuation;
6. `Codable` registration and persisted round-trip;
7. finalization, unused-value reporting, and concurrency tests.

Exact slice boundaries may become smaller when the implementation plan is
written. No slice should combine the repository quality bootstrap with runtime
architecture work.

## Consequences

Benefits:

- The first end-to-end path is small, portable, and useful in real tests.
- Standard-library random APIs remain available to application code.
- Multiple attachments address independent and concurrent random domains.
- The public extension boundary is exercised before complex first-party systems
  can accidentally depend on internal privileges.
- Replay exhaustion is deterministic and visible despite a nonthrowing native
  API.
- Omitting timestamps avoids data that has no replay effect.

Costs:

- A shared generator cannot deterministically assign values to racing callers
  without application coordination.
- A nonterminating diagnostic handler requires a fallback value after serious
  replay failure.
- Reference semantics differ from the value semantics of some concrete random
  generators.
- The first public extension boundary supports sequential synchronous behavior;
  later capabilities still require deliberate additional APIs.

## Explicit non-decisions

This decision does not determine:

- the initial real-time replay scheduler;
- stream or interaction helper APIs;
- matching policies for keyed operations;
- deterministic assignment of values to uncoordinated racing tasks;
- distributions or seeded pseudo-random algorithms;
- cryptographic suitability of any injected live generator;
- manual replay cursors or rewinding;
- exact Swift declaration names or package target layout.

## Review questions

1. **Stable and native API: Resolved.** Record ordered raw `UInt64` results and
   expose a reference-semantic generator conforming to `RandomNumberGenerator`.
2. **Attachment ownership: Resolved.** References to one generator share one
   atomic cursor. A scenario may attach any number of independently named random
   systems with separate generators and tracks.
3. **Replay exhaustion: Resolved.** Emit a serious diagnostic, invoke the
   configured handler, return zero only if it returns, and never use live
   randomness during replay.
4. **Product status: Resolved.** Random is a supported portable first-party
   Diorama system, not an internal fixture.
5. **Extension boundary: Resolved.** The random implementation uses the same
   public typed sequential-track facilities available to consumer systems, with
   external-module conformance tests.
6. **Live source: Resolved.** Record and passthrough use an injected generator
   that defaults to `SystemRandomNumberGenerator`; replay never consults it.
7. **Timing: Resolved.** Random observations retain sequence but no timestamp.
   This prompted the accepted revision to decision 3 making timing
   capability-specific rather than universal.

## Accepted answer

Diorama's first vertical system records and replays ordered raw `UInt64` values
through a reference-semantic `RandomNumberGenerator`. Each named attachment has
an independent source, track, atomic cursor, and lifecycle, and a scenario can
contain any number of them. Record and passthrough use an injected live source;
replay never does.

Replay exhaustion produces a serious diagnostic and invokes the configured
handler. If the handler returns, the generator returns zero as its documented
deterministic continuation. Finalization reports unused values through the
common verification model.

Random ships as a first-party portable product and is implemented entirely on
the public typed sequential-track extension boundary. Consumer-defined systems
can use that same boundary with optional `Codable` persistence. Random values
are demand-driven and retain no timing; decision 3 now reserves persisted
timing for behavior whose elapsed time affects replay.
