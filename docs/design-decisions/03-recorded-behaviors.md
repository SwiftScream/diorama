# Decision 3: Recorded behaviors

- Status: Accepted
- Last updated: 2026-09-05
- Depends on: [Decision 1: Common abstraction](01-common-abstraction.md),
  [Decision 2: Shared and system-specific semantics](02-shared-vs-system-semantics.md)

## Decision

How are returned values, thrown errors, callbacks, cancellation, ordering, and
elapsed time represented and replayed?

## Context

Decisions 1 and 2 established typed tracks, behavior-specific capabilities, and
a system extension boundary. This decision must give those tracks enough
structure to reproduce behavior without returning to one universal
request/response exchange.

Several distinctions matter:

- A returned value and a thrown error are alternative outcomes of one call.
- A completion-handler API may still be semantically a one-shot interaction.
- Repeated or unsolicited callbacks are a stream even when the native API does
  not expose `AsyncSequence`.
- A recording can end while an interaction or stream remains active. The lack
  of a terminal event can itself be behavior that replay must preserve.
- Caller cancellation is a runtime control action, not necessarily dependency
  behavior that Diorama should persist or verify.
- Record order and elapsed time are related but different. Two records may have
  an order without replay needing to wait between them.
- Wall-clock values and monotonic scenario time are different. A device clock
  can jump even while elapsed time continues monotonically.

## Options considered

### Store only completed snapshots

An interaction could store its input beside a returned value or error, and a
stream could store only its delivered elements.

This is compact and sufficient for simple sequential HTTP tests. It loses
overlapping operations, start-to-finish duration, active work at the end of the
recording, stream lifecycle, and the relationship between callbacks and their
owning operation.

### Use one universal event enum

The core could define cases for call, return, throw, callback, cancellation,
completion, and time advancement.

This can encode all initial examples, but it makes the core own the closed list
of behaviors that decisions 1 and 2 intentionally left extensible. Custom
systems would need generic escape-hatch cases, weakening type safety and
diagnostics.

### Use a small core envelope with capability-specific events

The core can preserve track position while each capability defines a typed
event vocabulary and retains only the timing that affects its replay behavior.
Systems can use a built-in event model or supply their own through the extension
boundary.

This retains common ordering infrastructure and shared logical-time services
without requiring every record to carry a timestamp or the core to interpret
every event.

## Proposed common record envelope

Conceptually, every track contains records shaped like:

```swift
struct TrackRecord<Event> {
    var sequence: UInt64
    var event: Event
}
```

This is illustrative, not a proposed final Swift declaration.

The fields have these meanings:

| Field | Meaning |
| --- | --- |
| `sequence` | Stable position assigned monotonically within one track. |
| `event` | A typed value interpreted by the owning capability or system. |

Sequence is always present because deterministic track order is a core
guarantee. Timing is not a universal envelope field. A capability records it
inside its typed behavior only when elapsed time changes observable replay:

- an interaction stores relative delays from invocation to its phases and
  conclusion;
- a stream stores publication offsets relative to its subscription or stream
  origin;
- a clock stores wall-time observations, while its runtime-only monotonic facet
  owns deadlines and sleep behavior;
- a synchronous demand-driven observation, such as a random value, needs order
  but no persisted timestamp.

This preserves HTTP round-trip behavior, stream spacing, and editable timing
without persisting incidental information such as when an unrelated random call
occurred. Shared logical time remains a core service available to systems that
need it; it is not mandatory data on every record.

The envelope should not contain a general string-to-value metadata dictionary.
Information required for replay belongs in a typed event or a later explicitly
designed core field. This keeps custom metadata from becoming an unversioned
secondary schema.

## Interaction events

An interaction should record separate correlated lifecycle events rather than
only one completed exchange:

```text
began(correlation, input)
observed(correlation, intermediate-event) // when the protocol exposes a phase
responded(correlation, phase-decision)     // when the client answers that phase
ended(correlation, outcome)
```

An outcome is one of:

```text
returned(output)
failed(failure)
```

Separate begin and end events provide:

- representation of concurrent in-flight calls;
- elapsed duration represented by relative phase and conclusion delays;
- diagnostics for calls that began but did not terminate;
- correlation of subsidiary events with an owning operation.

Intermediate events and decisions are typed by the system or protocol domain.
For HTTP, one logical request might observe a redirect response, decide whether
to follow its proposed request, receive an authentication challenge, provide a
challenge disposition, and only then produce its terminal response. These are
phases of the correlated interaction rather than separate unrelated exchanges.
Simple interactions do not pay for phases they never produce.

At the recording horizon, an interaction receives exactly one recording
conclusion: returned, failed, or open. These are cases of one value rather than
independent fields, so an interaction cannot both return a response and remain
open. For example, an HTTP request may be explicitly open after delivering an
authentication challenge that the caller never answered.

Replay selection remains decision 4. This decision only requires stable
correlation within a recording; it does not require calls to replay strictly in
recorded start order.

## Stream events

A stream should represent subscription lifecycle and delivery separately:

```text
subscribed(subscription, input-or-configuration)
delivered(subscription, value)
reported(subscription, failure)          // nonterminal when the API allows it
ended(subscription, completion-reason)
```

A completion reason distinguishes normal completion from terminal failure. A
separate nonterminal failure event is needed for callback APIs such as services
that can report an error and later continue delivering values.

A subscription also receives exactly one recording conclusion: finished,
failed, or open. The open case is normal for a long-lived location service and
must not be serialized as if the stream completed after its last recorded
value.

Multiple simultaneous subscriptions use distinct correlations. A system that
permits only one subscription can hide that identifier from its public model
while retaining it in the recorded representation.

## Callback classification

Native callback syntax does not create another core capability:

- A completion handler invoked at most once maps to an interaction outcome.
- Repeated or unsolicited callbacks map to stream events.
- Progress callbacks followed by a final result can use a correlated stream of
  progress events alongside an interaction outcome.
- Delegate APIs can compose interaction and stream tracks according to their
  semantic behavior.

Adapters preserve native execution contracts that matter, such as main-actor
delivery. Exact thread or queue identities are not snapshot behavior unless a
system explicitly models them.

## Semantic events and persistence grouping

Lifecycle phases need to remain semantically distinct, but this does not require
the persisted file to be one flat event array. A grouped representation can
nest the ordered lifecycle beneath its interaction or subscription:

```yaml
interactions:
  - id: request-a
    input: original-request
    lifecycle:
      - redirect: redirect-response
        decision: follow
      - authenticationChallenge: challenge
        decision: use-credential
    outcome:
      returned: final-response
```

This is the preferred direction because it keeps related behavior readable and
editable. A runtime recorder may still append events individually and group
them when producing the stable representation. The exact grouping, encoding,
and handling of unfinished interactions are deferred to the persistence and
schema decisions.

## Failures

Recorded failures must be stable, typed system or domain values. Diorama should
not attempt to persist an arbitrary `any Error` value or assume its runtime type
can be reconstructed in another process.

During recording, an adapter converts a native error into its stable failure
representation. During replay, it converts that representation into the error
expected by the native API. Decision 6 will determine exactly where these
conversions occur.

Recorded failures are dependency behavior and replay as such. Diorama
infrastructure failures, such as corrupt tracks or unmatched operations, remain
separate errors so tests cannot mistake a broken fixture for a recorded network
or location failure.

## Recording conclusion and cancellation

A finite snapshot has a **recording horizon**. When that horizon is reached, the
runtime recorder converts every interaction and subscription accumulator into
an immutable grouped recording with exactly one explicit conclusion:

```swift
enum InteractionConclusion<Output, Failure> {
    case returned(Timed<Output>)
    case failed(Timed<Failure>)
    case openAtRecordingHorizon
}

enum StreamConclusion<Failure> {
    case finished(at: Duration?)
    case failed(Timed<Failure>)
    case openAtRecordingHorizon
}
```

These declarations are conceptual rather than final API. Their sum-type shape
is the important constraint: returned, failed, finished, and open cases are
mutually exclusive. A missing conclusion is invalid data rather than an
implicit open state, so truncation or failed finalization cannot be mistaken for
intentional behavior.

`openAtRecordingHorizon` is not a terminal event in the recorded system. It is
an explicit statement that observation ended while the operation was active.
During replay, an open interaction reproduces its recorded phases and then
remains pending. An open stream delivers its recorded events and remains active.
The caller may later cancel either through the dependency's normal API, and
scenario cleanup must eventually release any remaining replay resources.

Diorama does not need to persist, inject, or verify caller cancellation. An
adapter may observe cancellation internally so it can stop live recording or
release a replay continuation, but that implementation event is not part of the
stable behavior by default.

If cancellation is independently emitted by the dependency as observable
behavior, the owning system can represent it as a stable terminal failure or
typed domain event. That is distinct from recording the caller's `cancel()`
action as an expectation.

## Ordering

The core retains the sequence of every record within its track. Capabilities
decide which sequence constraints affect replay:

- Stream deliveries preserve their semantic order within a subscription.
- Interaction begin order can be flexible when request matching permits it;
  correlated subsidiary and terminal events still remain attached to the right
  interaction.
- Clock observations preserve their capability-defined progression.
- Consumer systems define their own constraints without changing the core
  record shape.

Exact interleaving between tracks is not implicitly enforced. As accepted in
decision 1, explicit cross-track coordination is a setup-time feature whose
concrete mechanism is deferred.

## Time representation

Diorama should distinguish three concepts:

1. **Capture time** is an internal monotonic observation used to derive a
   capability's meaningful relative delays. It is not necessarily persisted.
2. **Replay logical time** is the simulated monotonic timeline onto which
   effective recorded or overridden delays are mapped during playback.
3. **Wall-clock observation** is a value returned by a clock system. It is
   represented as an editable ISO 8601 origin followed by signed deltas between
   successive observations.

These values often advance together, but keeping them distinct allows a wall
clock adjustment to be represented without making elapsed time move backward.
It also prevents an automatically advancing replay clock from distorting live
durations captured by another system in a mixed-mode scenario.

Live duration measurements must use a monotonic capture clock. Interactions
derive delays from their demand-driven invocation, while streams anchor
publication offsets to their subscription or stream origin. Mapping these
capability-specific timings onto replay logical time remains part of the later
scheduler design.

Incidental absolute chronology across independent tracks is not persisted.
Future cross-track coordination should use explicit setup constraints or typed
coordination markers rather than infer dependencies from coincidental capture
timestamps.

## Recorded values and authored overrides

Re-recording must not erase values deliberately authored to create test
behavior. Diorama therefore needs to distinguish a generated observation from
an explicit playback override rather than treating every scalar as anonymous
data.

For an overrideable timing value, the normalized runtime model can conceptually
use a sum:

```swift
enum RecordedValue<Value> {
    case observed(Value)
    case override(Value)
}
```

This maintains exactly one effective value after decoding. The persisted input
may be more permissive for editing convenience. Observed is the default and
does not need an explicit tag:

```yaml
conclusionDelay: 184ms
```

An explicit observed form may also be accepted, while an override must always
be explicit:

```yaml
conclusionDelay:
  observed: 184ms
  override: 12s
```

When both appear in persisted input, the override wins. The reader discards the
observed value as it constructs the mutually exclusive runtime value. This
allows a developer to add and later remove a temporary override without first
deleting the captured observation, as long as the file is not canonically
rewritten in between.

On re-record, an observed value is replaced with the new observation while an
override is preserved. Canonical output contains only the effective override
when one exists; the newly captured observation is discarded. A re-record
command may report that observation transiently without making it durable
fixture data.

This separates a tolerant editing format from a strict runtime model. Persisted
input containing neither an observation nor an override remains invalid. The
exact YAML or JSON syntax is deferred; the examples specify behavior rather
than a format commitment.

This mechanism may later apply to selected fields beyond timing, but not every
recorded field should automatically gain an override wrapper. Decisions 7, 9,
and 10 will define persistence layout, normalization, and re-record workflow.

## Replay timing

The initial scheduler maps logical duration to monotonic real duration at a
one-to-one rate. Systems with timed behavior therefore replay their effective
recorded or overridden delays in real time.

The initial implementation has one playback policy:

| Policy | Behavior |
| --- | --- |
| Real-time automatic | Diorama advances logical time with a monotonic host clock and waits the effective duration before delivering scheduled behavior. |

The ordinary path remains setup-only. A recorded HTTP phase after 250
milliseconds, for example, becomes eligible approximately 250 milliseconds
after its replay invocation. An authored 12-second override intentionally takes
approximately 12 real seconds. Stream spacing and clock sleeps follow the same
mapping.

Constant-factor acceleration is the leading next enhancement. A playback rate
of four would divide every effective delay by four while preserving relative
ordering. Manual advancement and fully virtual accelerated time remain possible
later enhancements. The initial design should avoid making them impossible but
should add no implementation machinery or public configuration solely for
them.

The exact monotonic clock, timer tolerance, deadline queue, and cancellation
mechanics are deliberately deferred to decision 14. Because initial time does
not jump forward, the scheduler does not need to detect global Swift-task
quiescence before advancing.

## Worked examples

### Concurrent HTTP calls

Two request-began events can exist before either response. Correlation attaches
each response or failure to the correct request. Replay may match requests by
HTTP properties even if the test starts them in a different order. A matched
outcome becomes eligible after its effective recorded or overridden logical
delay.

### Multi-phase HTTP call

One HTTP interaction begins with its original request, records a redirect and
the client's follow decision, records an authentication challenge and its
resolution, and ends with the final response. The phases remain correlated with
the original call. Authentication material will require the redaction rules
defined by decision 9.

### Location service

The location track records subscription, ordered location deliveries, and a
nonterminal error callback if one occurs. It may remain open at the recording
horizon. Successive nonnegative delivery delays relative to subscription and
the preceding event allow automatic replay to preserve meaningful spacing
without requiring the test to call Diorama after setup. Measurement timestamps
remain a separate wall-time value.

### Clock adjustment

A clock recording can have an origin of `10:00:00` and a later successive wall
delta of one hour and five seconds after an external clock adjustment. The
observation sequence reproduces the jump without making wall time the
scenario's monotonic scheduling clock.

### Unanswered authentication challenge

An HTTP call begins and receives an authentication challenge, but no challenge
decision or terminal response occurs before the recording horizon. Replay
delivers the challenge and leaves the interaction pending. A test timeout or
caller cancellation can then act through its normal injected dependencies.

## Recommendation

Use a minimal ordered record envelope with typed capability or system events.
Represent interaction and stream lifecycles as correlated events, model stable
failures and a mutually exclusive recording conclusion explicitly, and keep
monotonic scenario time separate from returned wall-clock values. Caller
cancellation remains runtime control rather than persisted behavior by default.

Replay should preserve semantic ordering while initially waiting the effective
real duration. Timing is persisted only for phases, conclusions, publications,
or other dependency behavior whose elapsed time affects replay; clock sleeps
remain runtime scheduler operations. Real-time automatic playback supports the
normal setup-only experience, declared timing overrides may survive
re-recording according to system policy, and scaled, manual, or fully virtual
playback controls remain future enhancements.

## Consequences

Benefits:

- Concurrent calls, streams, callbacks, failures, and open interactions can be
  represented without special cases in the scenario core.
- Relative timing supports representative slow-response, timeout, and race
  scenarios.
- Demand-driven records avoid unused timestamps and noisy snapshot diffs.
- One-to-one monotonic scheduling avoids global task-quiescence detection.
- Stable failures remain distinct from Diorama infrastructure errors.
- Mutually exclusive conclusions prevent returned, failed, finished, and open
  states from being combined invalidly.
- Custom systems can define new event types without changing a core enum.

Costs:

- Event lifecycles and correlation are more complex than paired exchanges.
- Adapters must preserve callback lifecycle and clean up open replay work.
- Tests wait for their effective recorded or overridden durations.
- Timer scheduling and platform tolerance require cross-platform validation.
- Each capability must define the origin and meaning of its timed behavior.
- Stable error conversion may lose native error details unless domains model
  them deliberately.

## Explicit non-decisions

This proposal does not determine:

- concrete Swift types or persistence encoding;
- how replay candidates are matched or selected;
- whether matched records are consumed and how unused records are reported;
- where native-to-stable conversion APIs live;
- setup, finalization, and timer scheduling algorithms;
- constant-factor, manual, and fully virtual playback policies;
- the syntax for cross-track coordination.

## Review questions

1. **Lifecycle records: Resolved.** Interactions and streams preserve distinct,
   correlated lifecycle events rather than only completed exchanges or value
   arrays. System-specific intermediate phases include behavior such as HTTP
   redirects and authentication challenges. Grouped persistence is the
   preferred representation, while its exact structure remains deferred.
2. **Cancellation and open work: Resolved.** Caller cancellation is not
   persisted, injected, or verified by default. Adapters may observe it as an
   internal resource-management event. Every grouped interaction and stream has
   one explicit, mutually exclusive recording conclusion, including
   `openAtRecordingHorizon`. This represents unanswered authentication
   challenges and long-lived streams without allowing a returned or failed
   recording to also claim it is open.
3. **Timing scope: Resolved, revised.** Timing is recorded only when it affects
   observable replay behavior. HTTP stores relative phase and conclusion delays;
   streams store publication offsets; clocks record wall observations while
   monotonic sleeps remain runtime-only scheduler operations. Demand-driven
   synchronous records such as random values have no timestamp. Track sequence
   remains universal.
4. **Authored overrides: Resolved.** The normalized model contains either an
   observed value or an override. Observed is the implicit persisted default and
   may also be written explicitly; override is always explicit. A reader accepts
   both together and gives the override precedence, supporting temporary manual
   experiments. Canonical writing and re-recording preserve only the override
   and discard fresh observations, which may instead appear in a transient
   report. Overrides apply only to deliberately selected fields.
5. **Playback time: Resolved, revised.** The initial implementation uses
   real-time automatic playback: logical duration maps one-to-one to monotonic
   real duration. Constant-factor acceleration is the leading next enhancement;
   manual advancement and fully virtual time remain future work.

## Accepted answer

Diorama records correlated, typed lifecycle events for interactions and streams,
including protocol-specific intermediate phases. Grouped recordings end in one
explicit, mutually exclusive conclusion: returned, failed, finished, or open at
the recording horizon. Caller cancellation is runtime control rather than
persisted or verified behavior.

Timing is capability-specific rather than part of every track record. HTTP
phases and conclusions retain invocation-relative delays, streams retain timed
publications, and clocks retain an ISO 8601 wall origin plus signed successive
observation deltas. Monotonic sleeps remain runtime-only scheduler operations,
and demand-driven synchronous values retain only sequence. Overrideable fields
normalize to either an observed value or an authored override; persisted input
may temporarily contain both, in which case the override wins. Re-recording
preserves the override and discards the fresh observation.

The initial replay implementation uses real-time automatic scheduling
exclusively. Logical time advances one-to-one with a monotonic host clock, so
effective delays wait for their corresponding real duration. Constant-factor
acceleration is the leading next enhancement. Manual and fully virtual policies
are deferred without requiring anticipatory implementation.

## Consistency review

The review after decision 3 found no conflict requiring decisions 1 or 2 to be
reopened. The later decision 13 discussion revised the original universal
timing rule: sequence remains common, while each capability persists only
behaviorally meaningful timing. Decision 2's mixed-mode support still requires
timed live observations to use a monotonic capture clock separate from replay
logical time. Their detailed coordination remains deferred to the lifecycle and
scheduler design.

## Later clarification

Decisions 7 and 8 place grouped records in an authoritative semantic scenario
and use deliberate `Codable` representations in a versioned JSON repository.
The YAML fragments in this decision remain notation examples, not a selected
file format.
