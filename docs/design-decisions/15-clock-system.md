# Decision 15: Initial clock system

- Status: Accepted
- Last updated: 2026-09-05
- Depends on: [Decision 1: Common abstraction](01-common-abstraction.md),
  [Decision 2: Shared and system-specific semantics](02-shared-vs-system-semantics.md),
  [Decision 3: Recorded behaviors](03-recorded-behaviors.md),
  [Decision 5: Consumption and verification](05-consumption-and-verification.md),
  [Decision 6: Runtime-to-snapshot conversion](06-runtime-to-snapshot-conversion.md),
  [Decision 8: Schema compatibility](08-schema-compatibility.md),
  [Decision 9: Normalization and redaction](09-normalization-and-redaction.md),
  [Decision 10: Lifecycle and ownership](10-lifecycle-and-ownership.md), and
  [Decision 14: Real-time replay scheduler](14-real-time-replay-scheduler.md)

## Decision

What native clock dependencies does Diorama provide, which clock behavior is
recorded, how are wall observations represented and edited, and how do clock
operations behave on replay failure and after finalization?

## Context

"Clock" describes two different dependencies that must not be conflated:

- a device wall clock returns a civil-time instant and can jump because of user,
  network, or system adjustment;
- a monotonic clock measures elapsed time and suspends work until deadlines
  without moving backward when civil time changes.

Diorama needs to replay observed wall values so tests can exercise behavior at
specific dates or across clock adjustments. Application timeouts also need to
share decision 14's scheduler with replayed HTTP and stream work. Recording
every monotonic read or sleep, however, would verify application implementation
and persist host scheduler noise rather than external dependency behavior.

## One system, two facets

One named clock-system attachment vends two distinct dependencies:

1. A **wall-clock facet** conforms to a small Diorama-owned protocol whose
   synchronous, nonthrowing `now` property returns `Date`.
2. A **monotonic facet** conforms to Swift's `Clock` protocol and uses the
   scenario scheduler for its instant, deadline, and sleep semantics.

Application setup may inject either or both facets. They share attachment
diagnostics and lifecycle but not the meaning of `now`. A civil-time adjustment
can change successive wall values without changing monotonic deadlines.

Clock attachments are optional. A scenario may contain only HTTP, location,
random, consumer-defined, or any other configured systems. Diorama does not
require one instance of each first-party system.

Any number of named clock attachments may coexist. Each has an independent wall
source and observation track. Their monotonic facets share the execution's
scheduler, origin, and playback rate so deadlines remain comparable within that
scenario.

## Wall-clock source

Record and passthrough use an injected `Sendable` synchronous source returning
`Date`. The default source reads the platform system wall clock. Each attachment
owns and serializes access to its source.

| Mode | Wall `now` behavior |
| --- | --- |
| Record | Read the live source, normalize it, append its signed delta, and return the native observed value. |
| Replay | Consume the next stable observation and materialize a fresh `Date`; never read the live source. |
| Passthrough | Return the live source value without reading or mutating the track. |

Concurrent reads against one attachment acquire one atomic order. As with the
random system, Diorama does not preserve which of two racing tasks wins that
order. Consumers can coordinate calls or attach separate clock systems when
independent domains require stable assignment.

## Stable wall representation

A nonempty wall recording contains:

- one ISO 8601 origin representing the first effective observation;
- an ordered list of signed deltas, where each entry is relative to the
  preceding effective observation;
- a first delta that canonically equals `0ms`.

For example:

```json
{
  "origin": "2030-01-01T09:00:00+11:00",
  "observations": [
    "0ms",
    "5s",
    "2s",
    "-1s"
  ]
}
```

This returns wall values at 09:00:00, 09:00:05, 09:00:07, and 09:00:06.
Signed deltas allow repeated values and backward wall-clock adjustments.

Successive deltas are preferred to offsets from the origin because editing one
delta naturally shifts that and every later wall value. Changing only one wall
value requires a compensating change to the following delta. Random access
requires accumulation, which is negligible and can be normalized to absolute
stable instants when loading.

Wall reads are demand-driven and carry no replay timestamp. A delta changes the
value returned by that and later reads; it does not make replay wait before
returning the value.

## Scalar encoding

Stable clock instants and deltas have millisecond precision.

The persisted duration reader accepts a strict, locale-independent grammar:

- signed integral milliseconds, such as `250ms` or `-1500ms`;
- signed seconds with at most three fractional digits, such as `5s` or `1.5s`.

Field validation decides whether a negative value is meaningful. Wall deltas
may be negative; HTTP delays and other elapsed durations generally may not.

Canonical duration output uses:

- `0ms` for zero;
- integral seconds when exactly representable, such as `5s`;
- integral milliseconds otherwise, such as `1500ms`.

The writer encodes the wall origin as ISO 8601 with an explicit numeric UTC
offset and at most three fractional digits:

```text
2030-01-01T09:00:00.125+11:00
```

The stable origin retains the absolute instant and selected numeric display
offset, so an authored `+11:00` is not silently canonicalized to `Z`. It does
not persist a regional timezone rule.

Each native absolute observation is independently rounded to the nearest
millisecond before successive deltas are calculated. This bounds each value's
normalization error and prevents interval-rounding error from accumulating.
Loading validates syntax, ISO 8601 values, and cumulative arithmetic before a
strict runtime track is created.

## Recording timezone

At attachment startup, record mode captures an encoding `TimeZone` supplied by
setup or defaults to `TimeZone.current`. The first observation resolves that
zone's numeric UTC offset at the observed instant, including daylight-saving
rules, and writes it into the ISO 8601 origin.

Timezone affects presentation only. Native `Date` values and successive deltas
remain absolute. Re-recording replaces an ordinary observed origin completely,
including its encoded timezone offset, using the current attachment
configuration. An authored origin override retains its authored ISO 8601 value
and offset.

## Authored overrides and re-recording

The origin and later observation deltas are deliberately overrideable fields
under decision 3's common observed-versus-override model.

Re-recording first builds a fresh observed track:

1. capture and independently round each new absolute wall observation;
2. use the first as the fresh observed origin;
3. calculate each new successive delta from those fresh values;
4. preserve a baseline origin override, if one exists;
5. preserve each later delta override that still has a new observation at the
   same sequence position;
6. publish ordinary fresh values at every other position.

New deltas are always calculated against the fresh observed sequence, not
against an older authored origin. Preserving an origin override therefore
shifts the new observed progression without creating large artificial deltas.

The tolerant reader permits an override at observation position zero. During
normalization its effective value is added to the origin, the origin becomes an
override when that shift was authored, and position zero becomes `0ms`. Later
successive deltas remain unchanged.

If a new recording no longer contains the position of an older delta override,
that override is dropped and publication may proceed. Version-control history
is the recovery mechanism. The finalization report may mention the discarded
override informationally but does not make the candidate unhealthy.

If re-recording produces no wall observations, it replaces the prior wall
payload with the valid empty case and drops its obsolete origin and positional
overrides.

## Empty wall payload

A configured clock attachment may validly contain no wall observations. Its
wall payload is an explicit empty semantic case with no origin. This is useful
when application code consumes only the monotonic facet.

The following states remain distinct:

- no clock attachment was declared in setup, which is always valid;
- a declared clock attachment has a persisted empty wall payload, which is
  valid;
- a replay clock attachment was declared but its named track is absent from the
  loaded scenario, which is a setup configuration error;
- a persisted clock attachment is not declared or explicitly ignored by setup,
  which follows decision 5's unattached-track diagnostic policy.

Calling wall `now` while replaying a valid empty payload is a runtime exhaustion
diagnostic rather than a setup error because monotonic-only use was valid.

## Wall replay consumption and exhaustion

Replay consumes wall observations strictly in sequence. Each returned value is
the effective origin plus the accumulated effective deltas through that
position. Call sites do not supply identifiers, and invocation time does not
participate in matching.

If an extra read has no observation to consume, Diorama:

1. records a serious structured diagnostic and invokes the configured handler;
2. repeats the last wall value it successfully returned if the handler returns;
3. returns the Unix epoch if no value was ever available;
4. never consults the live wall source.

Repeating the last value avoids inventing unrecorded wall progress. A test that
might poll until time changes should use the accepted trap-on-serious-error
handler. Finalization reports unconsumed wall observations through the common
verification report.

## Monotonic facet

The monotonic facet is runtime infrastructure rather than persisted behavior:

- `now` returns the current scenario logical instant;
- `sleep(until:tolerance:)` registers with decision 14's scheduler;
- cancellation throws `CancellationError`;
- reads, requested sleeps, completions, and scheduler lateness do not enter the
  clock track.

A requested sleep is application behavior, not an observation supplied by an
external dependency. Recording it would turn Diorama into a verifier of the
consumer's timeout implementation and would persist host scheduling noise.

The facet may honor a consumer-provided tolerance only within the stronger
deadline behavior promised by the scheduler. The initial scheduler requests
zero tolerance, so accepting a larger native tolerance does not make replay
less deterministic.

## Logical instant

The monotonic facet's `Clock.Instant` is a small `Sendable`, `Hashable`, and
`Comparable` logical value represented as a `Duration` from scenario start. It
contains no wall value, `ContinuousClock.Instant`, attachment key, or execution
UUID and is never persisted.

An instant at five seconds means five seconds after the receiving scenario's
start. This lets clock facets in one execution exchange deadlines naturally and
avoids an invalid cross-execution identity state that nonthrowing comparison
operators could not report safely. If an instant is passed to another
execution, that execution interprets the same logical offset against its own
origin.

Logical instant arithmetic uses checked internal conversion. Values outside the
supported duration range are programmer precondition failures rather than
silently wrapped deadlines. Persisted wall values and replay delays are
validated before reaching this API.

## Finalization and escaped handles

Finalization cancels pending monotonic sleeps and freezes the monotonic facet at
the recording-horizon logical instant. A pending sleep throws
`CancellationError` as scheduler ownership closes.

If a clock handle is used after finalization:

- monotonic `now` emits a lifecycle diagnostic and returns the frozen horizon
  instant;
- wall `now` emits a lifecycle diagnostic and repeats its last returned value,
  or the Unix epoch when none exists;
- a new sleep emits a serious diagnostic and throws a distinct Diorama
  execution-closed error.

No post-finalization operation falls back to a live source, including record or
passthrough handles. This makes an escaped dependency visible and prevents it
from silently outliving scenario ownership.

## Portability and product status

The wall domain, stable scalar codecs, system API, and monotonic facet are
portable first-party Diorama functionality. They use Swift and Foundation APIs
available to the package's macOS, iOS, and Linux targets. No Core Location or
URLSession target is required to use them.

Foundation conversion, ISO 8601 formatting, current timezone behavior,
millisecond rounding, `Date` range, and `ContinuousClock` scheduling require
cross-platform conformance tests. Platform differences that cannot meet the
stable contract must fail capability validation rather than changing persisted
meaning silently.

## Implementation progression

The clean-slate plan should divide the clock milestone into small slices:

1. stable millisecond duration and ISO 8601 origin codecs;
2. strict nonempty and empty wall semantic models with cumulative validation;
3. wall source injection and record/passthrough capture;
4. sequential replay, exhaustion diagnostics, and unused reporting;
5. origin and positional override normalization and re-record merge;
6. logical instant and Swift `Clock` conformance over scheduler services;
7. cancellation and post-finalization behavior;
8. multiple-attachment, concurrency, and cross-platform conformance tests.

Exact Swift APIs remain subject to atomic implementation review. Each accepted
slice must work through the public system extension services rather than
receiving private storage or diagnostic access.

## Consequences

Benefits:

- Wall adjustment and elapsed scheduling cannot corrupt each other's semantics.
- Origin overrides relocate an entire clock recording with one edit.
- Successive deltas make inserting a wall-time shift locally editable.
- Standard Swift `Clock` APIs participate in the scenario scheduler.
- Monotonic operations avoid snapshot noise and do not verify caller logic.
- Empty wall tracks support monotonic-only use without making clock mandatory.
- The system remains portable and permits multiple independent wall timelines.

Costs:

- Wall replay is sequential and cannot distinguish uncoordinated racing callers.
- Delta encoding requires accumulation and can make a one-value correction
  touch the following delta.
- Millisecond normalization deliberately loses sub-millisecond wall precision.
- A nonthrowing exhausted wall read needs a deterministic fallback.
- Overrides are position-based and may move when earlier observations are
  inserted or removed.
- Clock instants are logical offsets, not globally meaningful host instants.

## Explicit non-decisions

This decision does not determine:

- constant-factor, manual, or fully virtual playback controls;
- calendars, locale-specific formatting, or regional timezone persistence;
- seeded or simulated wall-clock progression between recorded reads;
- automatic matching of positional overrides after observations are inserted;
- a throwing wall-clock observation API;
- exact Swift declaration names or package target boundaries.

## Review questions

1. **Native facets: Resolved.** One optional named clock attachment vends a
   recorded wall-clock dependency and a scheduler-backed Swift `Clock` facet.
2. **Wall representation: Resolved.** A nonempty track stores an ISO 8601 origin
   and signed successive observation deltas; the first canonical delta is zero.
3. **Scalar encoding: Resolved.** Wall data uses millisecond precision, ISO 8601
   origins with explicit numeric offsets, and strict human-readable `s`/`ms`
   duration strings.
4. **Timezone and source: Resolved.** Record and passthrough use an injected
   wall source. Recording defaults to `TimeZone.current`, allows setup override,
   and rewrites an ordinary observed origin on re-record.
5. **Overrides: Resolved.** Origin and later deltas may be authored overrides.
   Position-zero overrides normalize into the origin; missing positions may be
   replaced on re-record without blocking publication.
6. **Replay exhaustion: Resolved.** Sequential wall reads diagnose exhaustion
   and repeat the last returned value, or the Unix epoch if none exists, without
   live fallback.
7. **Monotonic persistence: Resolved.** Logical reads and sleeps use the
   scheduler but are not recorded or verified as snapshot operations.
8. **Logical instant: Resolved.** Swift `Clock` instants are transferable
   scenario-relative durations without runtime clock or execution identity.
9. **Empty and missing clocks: Resolved.** Clock systems are optional. A
   configured empty wall payload is valid, while a configured replay attachment
   missing its named persisted track remains a setup mismatch.
10. **Finalization: Resolved.** Pending sleeps cancel, monotonic time freezes,
    and escaped handles diagnose use without returning to live dependencies.

## Accepted answer

Diorama's optional first-party clock system separates recorded wall observations
from a scheduler-backed monotonic Swift `Clock`. Wall recording uses an injected
source and stores a millisecond ISO 8601 origin followed by signed successive
deltas. Reads replay sequentially and never access live time.

Origins and later deltas support authored overrides. Re-recording derives fresh
deltas from fresh observed values, preserves applicable overrides, and permits
obsolete positional overrides to disappear. Empty wall payloads are valid for
monotonic-only use.

Monotonic instants are scenario-relative durations. Monotonic reads and sleeps
remain runtime scheduler operations rather than persisted expectations.
Finalization cancels sleepers, freezes logical time, and makes escaped-handle
use deterministic and diagnostic. The complete system is portable across the
initial macOS, iOS, and Linux targets.
