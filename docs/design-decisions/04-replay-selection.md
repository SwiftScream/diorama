# Decision 4: Replay selection

- Status: Accepted
- Last updated: 2026-09-04
- Depends on: [Decision 1: Common abstraction](01-common-abstraction.md),
  [Decision 2: Shared and system-specific semantics](02-shared-vs-system-semantics.md),
  [Decision 3: Recorded behaviors](03-recorded-behaviors.md)

## Decision

Is replay sequential, matcher-based, keyed, or selectable per system?

## Context

Decision 3 established grouped interaction and stream recordings containing
correlated lifecycle phases and one conclusion. Replay must first choose the
right group, then let the owning capability reproduce its internal behavior.

Different behavior shapes have different natural selection semantics:

- An HTTP interaction is normally selected by properties of its request.
- Repeated identical requests may need successive recorded outcomes.
- Concurrent requests may arrive in a different order from the recording.
- A location service may select one recorded subscription and then deliver its
  events sequentially.
- Each attached clock progresses sequentially through the interactions in its
  own recording; multiple clock attachments remain independent.
- A custom system may have a natural key or progression unlike any of these.

Selection is routing, not interaction verification. A selector identifies which
recorded behavior Diorama can supply for a live operation. End-of-test checks
and unused recordings remain decision 5.

## Selection stages

Selection should occur in stages rather than through one scenario-wide
algorithm:

```text
scenario
    -> system attachment identified by its setup key
        -> track owned by that attachment
            -> capability selects a grouped recording
                -> correlated lifecycle replays within that group
```

The scenario core owns track lookup and validates the selector's result. The
capability or system owns how a live input is compared with candidate grouped
recordings. A protocol domain may provide the default comparison policy.

## Attachment keys and match keys

Two distinct identifiers must not be conflated:

1. A **system attachment key** is supplied during scenario setup. It identifies
   one configured instance of a system and scopes all tracks and replay state it
   owns.
2. A **match key** may be derived by a system from a live input and recorded
   input. It is an optional implementation technique for selecting a grouped
   recording within that attachment.

For example, the same clock system can be attached as `device-clock` and
`server-clock`. Each attachment has an independent sequence of clock
interactions, despite both using the same capability implementation. Two HTTP
systems can likewise be attached for separate clients or upstream services, and
each matcher searches only its attachment's recordings.

Application calls do not carry the attachment key. Setup connects the native or
injected dependency to the corresponding attachment once, preserving the goal
that ordinary tests do not interact with Diorama after setup.

Application calls also do not carry match keys or other test identifiers. A
system understands its domain well enough to provide a useful default matching
policy. Setup may configure that policy in domain terms, such as whether an HTTP
header participates in matching. The system may derive a hash key, scan values,
or use another implementation internally without changing those semantics.

For example, an HTTP policy might ignore `User-Agent` by default but allow a
consumer to include it when server behavior genuinely varies by user agent. The
exact HTTP defaults and configuration surface remain decision 11.

The exact key types, default naming ergonomics, and persisted namespace format
are deferred. The core requirement is that every attached system instance has a
stable, unambiguous identity within its scenario.

For a multi-phase interaction, later inputs can also select a continuation. An
HTTP adapter may deliver a redirect or authentication challenge and observe the
client's decision before the system can choose the next recorded phase. This is
still selection of available behavior, not an assertion that application code
must reproduce an exact global event sequence.

## Options considered

### Strict global sequence

Every live operation could consume the next recording in track order.

This is deterministic and works for scripts or repeated operations whose inputs
carry no identity. It is brittle for concurrent HTTP calls: harmless scheduling
changes can make two requests arrive in the opposite order and receive each
other's behavior.

Strict sequence is useful for some systems but should not be universal.

### Stateless matcher

A matcher could search every recording and return the best matching one.

This supports reordered calls, but a stateless matcher repeatedly selects the
same recording for identical inputs. It cannot reproduce successive different
outcomes without consumption state, which belongs to decision 5. Broad matches
can also hide ambiguity unless selection results are explicit.

### Match-key lookup

Each live input and recording could have a derived match key.

Match keys make lookup efficient and deterministic when the domain has a stable
identity. They are not universal: location subscriptions may have no meaningful
match key, and requiring application code to add test-only identifiers would
damage the setup-only experience. A match key is therefore one possible
implementation of a system matcher, not a core requirement. This does not
remove the separate setup-time attachment key.

### Capability and system selectors

Each capability can provide selection semantics appropriate to its behavior,
and each system can refine them with domain knowledge. Selection policies are
configured at setup rather than chosen by individual calls in test code.

This reuses sensible defaults while allowing custom systems to remain honest
about their behavior.

## Proposed selector contract

The core should support a conceptual result such as:

```swift
enum ReplaySelection<RecordingID> {
    case selected(RecordingID)
    case noMatch(SelectionDiagnostics)
    case ambiguous([RecordingID], SelectionDiagnostics)
}
```

This is not a final Swift API. The important properties are:

- A selector operates on stable system or domain inputs, not runtime-native
  client objects.
- Selection is deterministic for the same input, candidates, and replay state.
- A selected identifier refers to a complete grouped recording, including its
  phases, timing, and conclusion.
- No match and unresolved ambiguity are explicit outcomes with structured
  diagnostic context.
- A selector does not contact the live dependency or mutate snapshot data.
- Consumption state, when adopted, is supplied separately from matching logic.

A selector can derive a hashable match key for indexing, evaluate equality, or
rank candidates directly. The core should not require one technique.

## Capability defaults

### Interaction

An interaction selector compares the live stable input with recorded inputs
using a system or domain matcher. It returns an ordered set of eligible
candidates or one explicit selection.

The initial default should be exact equality when the stable input supports it.
Domains such as HTTP should provide a meaningful default matcher rather than
requiring exact equality of every recorded field. The specific HTTP fields are
deferred to decision 11.

When several candidates are equivalent, recorded order is the deterministic
tie-break. Decision 5 determines whether selecting the first candidate makes it
unavailable so the next identical call receives the next recording.

### Stream

A stream system selects a grouped subscription recording when the caller
subscribes or starts the service. If subscription configuration is meaningful,
a domain matcher compares it. Otherwise, subscriptions are selected in recorded
order.

After selection, values, nonterminal failures, and the conclusion replay from
that group in semantic order. Individual emitted values are not independently
matched against caller actions.

### Clock

A clock attachment is selected once during setup by its attachment key. Each
wall `now` operation consumes the next observation from that attachment's
recorded sequence without running a general input matcher. Monotonic `now` and
sleeps use the shared runtime scheduler and do not consume persisted records.
No operation searches recordings belonging to another clock attachment.

### Custom system

A custom system can use a built-in capability selector or define its own
deterministic policy through the system extension boundary. Full custom behavior
engines may remain a later implementation milestone as accepted in decision 2.

## Multi-phase continuation

Selecting an interaction chooses its recorded path, but some phases receive
another live input. For example:

```text
request selected
    -> redirect delivered
        -> caller follows or declines
    -> authentication challenge delivered
        -> caller supplies a disposition
    -> conclusion
```

The system owns comparison of each live decision with available recorded
continuations. If the selected recording has no compatible continuation,
Diorama cannot faithfully supply further behavior and returns a structured
selection failure. It should not silently replay a continuation belonging to a
different decision.

An initial implementation may support only a single recorded path and require
compatible phase decisions. Branching several continuations beneath one initial
input can be added when a concrete system needs it.

## No-match behavior

A replay selection miss is a Diorama infrastructure failure, not a recorded
dependency failure. It should identify:

- the system and track;
- the live input or a safe diagnostic representation;
- the matcher or selector policy;
- relevant candidate differences where the domain can provide them.

Replay never accesses the live dependency on a miss or ambiguity. This is a hard
mode invariant rather than a configurable policy. A test that needs live
behavior uses record or passthrough mode for that system instead.

## Selection during re-recording

Authored overrides from decision 3 must survive re-recording. Matching a new
observation to an existing grouped recording therefore needs stable domain
identity.

The same domain match key or equivalence rules should normally support both
replay candidate discovery and re-record merge. Their failure policies differ:

- Replay can use deterministic recorded order among equivalent candidates.
- Re-recording must not move an override to the wrong interaction silently. An
  ambiguous merge should preserve the existing fixture and report that manual
  resolution is required.

Correlation identifiers created during one execution are not sufficient merge
keys because a later recording may generate different identifiers. Repeated
equivalent interactions may additionally need occurrence identity; that is
coupled to the consumption and persistence decisions.

## Worked examples

### Reordered HTTP requests

A recording contains `GET /profile` followed by `GET /weather`. During replay,
the tasks begin in the opposite order. An HTTP matcher selects each grouped
interaction by stable request properties, so scheduling does not swap their
responses.

### Repeated identical request

Two `GET /updates` interactions have equivalent requests but return different
bodies. Matching identifies both as candidates and recorded order breaks the
tie. Whether the first selection is consumed so the second call advances to the
next response is decided in decision 5.

### Location subscriptions

A test starts location updates twice during one scenario. The initial location
system selects the two subscription groups strictly in recorded order; mutable
manager configuration is not a replay match key. Each selected group then
replays its own timed delivery sequence.

### Multiple instances of one system

A scenario attaches two clocks as `device-clock` and `server-clock`. Reading the
device clock advances only the device clock's recorded interaction sequence.
The server clock retains its own next interaction. The same scoping applies when
two HTTP clients use the same HTTP capability and matcher implementation.

### Authentication branch mismatch

The selected HTTP recording contains an authentication challenge followed by a
recorded `useCredential` continuation. If replaying application code responds
with `cancelAuthenticationChallenge`, the HTTP system reports that it has no
recorded continuation instead of returning the credentialed response.

## Recommendation

Make replay selection capability- and system-specific behind a small core
selection contract. Use input matching for interactions, subscription matching
or sequence for streams, and sequential interactions within each keyed clock
attachment. Treat derived match keys as an optional matcher implementation
rather than a universal requirement. A separate attachment key identifies each
configured system instance during setup.

Configure policies at scenario setup. Do not impose global sequential replay,
require test-only keys in native calls, or silently contact live dependencies on
a miss. Replay has no live fallback.

## Consequences

Benefits:

- Concurrent and reordered interactions can replay correctly.
- Sequential systems retain simple deterministic behavior.
- Protocol domains can offer useful defaults and diagnostics.
- Custom systems are not forced into HTTP-style matching.
- Selection remains separate from end-of-test verification.

Costs:

- Systems must define deterministic matching or sequencing rules.
- Equivalent repeated inputs depend on consumption semantics from decision 5.
- Multi-phase inputs can require continuation selection.
- Re-record merging needs stricter ambiguity handling than ordinary replay.

## Explicit non-decisions

This proposal does not determine:

- whether a selected recording is consumed;
- behavior for unused recordings at scenario finalization;
- the default HTTP match fields or normalization rules;
- concrete selector APIs and type erasure;
- stable persistence identifiers and occurrence keys;
- whether multi-path branching ships in the initial release.

## Review questions

1. **Selection ownership: Resolved.** Selection belongs to capabilities and
   systems behind a small core result contract rather than one global algorithm.
   Diorama may provide reusable selector helpers without imposing them.
2. **Initial defaults: Resolved.** Matcher-based interactions and
   matcher-or-sequence stream subscriptions are suitable defaults. Every system
   instance receives an attachment key during setup. An attached clock selects
   its next recorded interaction sequentially within its own attachment; the
   same clock or HTTP system can be attached more than once under different
   keys.
3. **Match keys and customization: Resolved.** Application code does not provide
   test identifiers. Systems provide domain-aware matching defaults and expose
   setup-time options for relevant fields, such as whether `User-Agent`
   participates in HTTP matching. A derived match key is an internal
   implementation option rather than public request data. Integration authors
   may define custom selection logic, and Diorama may provide reusable helpers.
4. **Misses and ambiguity: Resolved.** No match or unresolved ambiguity fails
   with structured diagnostics. Replay never contacts the live dependency; this
   is a hard invariant rather than a default with a fallback option.
5. **Re-record identity: Resolved.** Replay matching rules also provide
   candidate identity for preserving overrides during re-recording. A unique
   correspondence preserves the override; an ambiguous merge preserves the
   existing authored data, reports diagnostics, and never reassigns an override
   silently.

These resolved points are the accepted answer to decision 4.

## Later clarification

Decision 5 distinguishes an operation-level replay failure from a test
framework failure. A miss or ambiguity always records an immediate diagnostic
and fails the native operation when its API has a failure channel. Diorama's
core does not itself declare the test failed. Non-failable APIs require an
explicit deterministic system-specific continuation policy and still never
contact the live dependency.
