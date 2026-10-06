# Decision 19: System-owned records and shared execution services

- Status: Accepted
- Recorded: 2026-10-06
- Approved by owner: 2026-10-06
- Authority: The owner accepts this decision and the revised delivery plan and
  authorizes a PR for the combined E04R/revised E05 refactor. Merge and starting
  the next implementation unit still require separate owner instructions.
- Reconciles: Decisions 2–5, 13–14, 16–17.
- Investigation: [Interaction primitives consideration](../interaction-primitives-design-consideration.md).

## Accepted decision

Core orders, reserves, validates, selects, and claims **typed records**. The
system defines what one record means. One record may be a random observation,
a location update session, or a complete recursive HTTP operation. A record
need not conform to an interaction, subscription, or grouped-lifecycle protocol.

Retain DD17's recursive HTTP representation. Remove `InteractionRecording`,
`SubscriptionRecording`, their accumulators, and the requirement for generic
interaction or subscription delivery engines in Core. Implement location's
session and access behavior in DioramaLocation and HTTP's lifecycle in
DioramaHTTP, with native supplements owned by the URLSession system.

Keep the shared execution services those systems actually need. Do not replace
Core with a container that makes every system reimplement ordering, single-use
claims, time, shutdown, and reporting. Do not introduce an optional helper
product or unused generic record types now. A future helper needs a concrete
first-party use and a demonstrated invariant that it simplifies.

## Why change the boundary

The existing interaction model has one input, observations with optional
answers, and a separate returned/failed/open conclusion. It validates temporal
ordering, but cannot enforce the relationships among HTTP responses, decisions,
partial bodies, and continuations. Wrapping DD17's entire tree inside its output
would duplicate the conclusion and supply no meaningful lifecycle service.
Its invocation-relative decision timestamps also retain application latency
that HTTP deliberately excludes.

Subscriptions have a stronger apparent fit, but DD16 provides the counterexample
to keeping that abstraction prematurely. Location stores successive delivery
delays, separate measurement deltas and origins, batches, cached state, and an
access lifecycle with authorization barriers. Every native update failure is
nonterminal. Generic finished/failed stream cases and subscription-relative
moments do not themselves implement that contract. They add conversion and
validation boundaries before any first-party system uses them.

“Grouped” remains useful descriptive language for related behavior. It is not a
second kind of track, a core capability, or a runtime type requirement. The
system's strict value supplies the grouping.

## Options considered

| Option | Benefit | Cost and conclusion |
| --- | --- | --- |
| Keep the current helpers and wrap HTTP | Small immediate diff | Competing conclusions, wrong timing defaults, and little useful reuse. Reject. |
| Generalize interactions into a configurable phase/state engine | Could centralize some transition code | Core must model response ownership, typed decision edges, open partial states, and domain validation, or delegate all of them back out. No demonstrated first-party simplification. Reject for this milestone. |
| Use strict ordered HTTP phases | Compact linear traversal of an observed path | Viable only with an HTTP-specific constructor and validator; does not justify generic Core interactions. Less direct ownership than the accepted tree. Do not replace DD17. |
| Move the same generic helpers into another product | Keeps Core smaller | Retains the speculative surface and maintenance burden with no first-party consumer. Defer rather than relocate. |
| Let systems implement everything | Maximum freedom | Duplicates atomic claims, admission, health, scheduling, and shutdown. Reject. |
| System-owned records over shared execution services | Preserves strong domain types and existing common invariants | Systems implement their own lifecycle construction and traversal. Adopt this boundary; test those obligations with each first-party system. |

## Concrete HTTP representation comparison

Both candidates store only the observed path, never alternative possible
histories. The following notation abbreviates prepared message and failure
values; it is not a new persisted schema or a dependency adoption.

The recursive form is DD17: `Operation(initialRequest, attempt)`, where an
attempt is `received(head, next)`, `failed(delay, failure)`, or `open`. A response
owns a body or a typed redirect/authentication continuation; an observed native
response-disposition supplement gates body delivery. Each typed branch owns
its next attempt, current response body, failure, or open leaf. There is no
root conclusion in addition to that leaf.

A credible ordered alternative is `Operation(initialRequest, continuingPhases,
currentAttempt)`. A continuing phase owns exactly one response and an answered
redirect or authentication decision that actually proceeds to another attempt.
`currentAttempt` owns the unfinished or concluding response, decision, body, or
pre-head failure. Refusal and unanswered decisions cannot be continuing phases.
Construction validates the whole sequence and derives effective requests at
each edge. A permissive array of observations plus a separate outcome is not
this strict alternative.

| Case | Recursive representation | Strict ordered alternative |
| --- | --- | --- |
| Successful response | Root attempt receives one head and body; body owns segment profile and returned leaf. | Empty continuing phases; current attempt owns the same response/body/returned leaf. |
| Authentication, redirect, success | 401 owns credential decision and retry; retry's 302 owns follow decision and next response. Derived requests are not duplicated. | Two continuing phases, each owning its response and decision; current attempt owns success. Validator derives request changes across both phases. |
| Refused redirect | Redirect response owns refusal and its delivered body; no subsequent attempt. | Refusal belongs to the current attempt, never to continuing phases; subsequent phases are invalid. |
| Canceled authentication | Challenge response owns cancel disposition and one resulting timed failure. | Current attempt owns the canceled challenge and failure. A cancel cannot appear in the continuing prefix. |
| Failure before response | Attempt is a timed failure with no invented head/body. | Current attempt is that failure after zero or more continuing phases. |
| Failure during body | Response owns exact delivered prefix, weighted segments, and one failed leaf. | Current response owns exactly the same prefix/profile/failure; no competing root failure. |
| Unanswered challenge or redirect | Observed response owns pending decision and open leaf. | Current attempt owns pending phase; construction rejects later phases. |
| Open body | Response owns observed prefix/profile and explicit open leaf. | Current attempt owns the same open body; no terminal completion is inferred. |
| Native response disposition | Only an observed supplement is present: allow owns body, cancel owns failure, unanswered owns open. | Same typed supplement on the current response; representation alone does not establish bridge support. |
| Edited body or delay | Exact bytes remain authoritative; weights scale deterministically; compatible structural paths retain delay overrides. | Requires the same rules, plus correspondence of continuing phases under edits. Positional array indices alone cannot retain overrides safely. |

The ordered alternative can meet these cases. Its validity depends on almost
all the same HTTP-specific sum types and validation rules as the tree. The tree
already expresses the ownership locally, is accepted, and makes the single
active leaf explicit. Replacing it creates schema and authoring work without
reducing Core's responsibilities. Retain it.

### Capture, freeze, and replay

Both representations require a domain accumulator that accepts prepared values
at native boundaries, correlates observations to the active attempt, reserves
observation order before conversion, and rejects duplicate or incompatible
transitions. Failure to prepare an observed event invalidates the candidate;
it is never converted into a healthy open leaf.

At freeze, the domain atomically detaches its mutable state. A genuinely pending
operation produces the appropriate open leaf, preserving its head, phase, and
body prefix. A still-converting or failed observation produces no complete
record. The recursive builder freezes the current leaf and its enclosing edges;
the ordered builder freezes the continuing prefix and strict current attempt.
Core reserves one position before builder construction and validates the final
already-prepared record without rerunning redaction or normalization.

Replay claims the complete record once. The domain traverses only its observed
path, checking current prepared decisions against the recorded branch. It
registers reachable delivery through Core's scheduler, acknowledges handoff,
and stops future delivery on cancellation or shutdown. A mismatch neither
reclaims the record nor consults a live source. The ordered form iterates its
validated prefix; the recursive form follows the selected continuation.

### Timing proof

A challenge at 100 ms, application answer at 600 ms, and response at 650 ms
records a 50 ms continuation delay. It does not record the application's 500 ms
wait. If replay answers at 2 seconds, the next head is due at 2.05 seconds; if
it answers at 200 ms, the next head is due at 250 ms. Both early and late answers
therefore preserve the delay from the current decision.

The system captures the current decision completion and computes its deadline
using `ExecutionTime.logicalTime(after:from:)`. Zero or overdue deadlines still
use the scheduler's next drain, never synchronous callback delivery. Body
segment delays accumulate from the appropriate head/allow/previous-segment
anchor. Callback execution lateness does not implicitly rewrite the profile.

## Shared services and their first-party justification

| Core service | First-party need | Enforced invariant |
| --- | --- | --- |
| Atomic append and typed tracks | Random and wall observations | Reservation order, preparation, attachment isolation, candidate health. |
| Incremental record registration and freeze | HTTP in-flight operation; location update session/access capture | One ordered slot, one freeze, whole-record validation, mode/closure enforcement, released callback captures. |
| Sequential claims | Random, wall, location sessions | Single use, deterministic next record, exhaustion, no rollback. |
| System-selected record claims | HTTP prepared request matching | Validate track-scoped identities and claim earliest available equivalent record atomically. |
| Logical time and scheduler | HTTP continuations, location deliveries/barriers, monotonic clock | Checked local deadlines, cancellation versus handoff, acknowledgement, quiescence. |
| Record claims and consumption reporting | HTTP and location delayed/open work | Claims are immediate and irreversible; system-reported consumption and progress are separate, value-free facts. |
| Preparation, diagnostics, finalization | All systems | Prepared-only admission, safe retained evidence, immutable result, no implicit test outcome. |

`beginRecord(preparation:capturing:freeze:)` exposes the existing reservation
mechanism for any `Sendable` domain accumulator. Core invokes freeze exactly
once after successful construction, including a constructor that returns after
admission closes (whose value is discarded). The domain owns synchronization
against observation, strict construction, late-observation rejection, and
release of its native and time references. Core cannot infer those rules from
an opaque builder; domain conformance tests must prove them. A factory that
throws owns cleanup of resources it did not return. Freeze and validation must
not synchronously wait for execution finalization.

`ReplaySelector<Input, Value>` requires only `Sendable` values. It computes
stable candidate identities without live access or mutation; Core checks the
identities and current availability under its lock. No-match, exhaustion,
ambiguity, and invalid results remain distinct. Sequential and selected claims
share the same claimed-record ledger.

`claim(matching:using:)` returns an unconsumed claim with no lifecycle
projection. The system reports monotonic progress and calls `markConsumed()`
after replaying all recorded behavior. `consumeNext()` combines claiming and
consumption for synchronous values. Core tracks these facts independently and
cannot validate the truth of a domain's acknowledgement. The accepted
[claim/consumption amendment](#claim-and-consumption-amendment--2026-10-06)
defines the reporting contract, including open recordings.

### Location access is not an update subscription

DD16's access lifecycle retains ordered authorization barriers and notifications.
Use an access track with an initial observation segment followed by one record
per authorization-request barrier. Each segment owns the ordered notifications
up to the next barrier; initial/current access state remains separate from
consuming reads. This partitions storage while preserving one ordered runtime
state machine.

Registering observation claims the initial segment. After its notifications
reach the next barrier, only the matching request may claim the next segment;
its notification delays anchor to that current request. Wrong, duplicate, or
early requests diagnose without claiming or searching past that barrier.
Unrequested segments remain unclaimed Core records, so claiming the initial
segment cannot hide unmet requests. Spontaneous notifications require no
invented request and remain inside the preceding segment.

This is the accepted G03/G05 mapping, not an open choice between custom
verification and record accounting. Update-session emissions remain internal
to their one session claim. DD16's demand-driven barriers justify distinct
access records without turning all nested lifecycle events into consumption
units. End-of-segment means the next barrier is reached, not that the native
access service terminated.

## Reconciliation with accepted decisions

The owner accepts these amendments on 2026-10-06. Earlier texts remain
historical records; this reconciliation governs where their illustrative Core
capability models differ from the system-owned record boundary.

- **DD02:** Ownership layers remain; the initial release no longer promises
  built-in generic interaction/stream engines. Domain lifecycle services sit
  with the systems that can enforce them. Consumer systems use the same Core
  services without a closed capability taxonomy.
- **DD03:** Correlation, strict mutually exclusive conclusions, explicit open
  horizons, prepared failures, and cancellation semantics remain. Its illustrative
  enums are domain constraints, not mandated public Core types. Local timing is
  determined by DD16/DD17, not generic invocation-relative moments.
- **DD04:** “Grouped selection” means selection of one complete system-defined
  record. Matching stays system-owned; equivalent records use FIFO. HTTP
  continuation compatibility is private traversal after the initial claim.
- **DD05:** Claiming and consumption are distinct. Core reports identities,
  progress, and consumption acknowledgements without terminal/open classification.
  Authorization-barrier segments retain DD16's independent unclaimed-request facts.
  The amendment below supersedes terminal-completion evaluation and its open exemption.
- **DD13:** Consumer-module proof demonstrates access to real shared services;
  synthetic APIs do not establish demand for extra behavior engines.
- **DD14:** Core retains deadlines, ordering, non-reentrancy, cancellation, and
  acknowledgement. Systems register reachable work and choose current-decision
  anchors. Its old HTTP invocation-deadline example remains superseded by DD17.
- **DD16:** Location owns strict sessions, successive delivery timing, cached
  state, nonterminal failures, and access barriers. No generic stream schema is
  required and no callback may be lost through generic termination rules.
- **DD17:** Retain the recursive HTTP tree, single ownership of messages and
  leaves, exact body and override rules, local delays, capability rejection,
  and native exceptions. This decision changes supporting infrastructure, not
  those HTTP semantics.

## Delivery and review boundary

[Plan 003](../plans/003-clean-slate-implementation.md) records E04R and revised
E05 as the combined refactor accepted by the owner on 2026-10-06.
E06/E07's generic engines are superseded by G03/G03A–G05 and H05–H12B; E08 proves
shared services without requiring those future domains. Full native behavior
remains in the existing G/H/I conformance units.

The unmerged `003-e05-system-selectors` and `003-e06-stream-delivery` branches
are preserved. E05 claim logic is adapted on this branch. E06's stream engine
must not be merged unchanged; its ordering/cancellation tests can inform G04.
The E07A lease assessment found on that stack is resolved here: retain one typed
track lease, with domain-specific models and delivery outside Core. A further
lease decomposition requires measured implementation benefit, not three
capability-specific lease types.

No new dependency, HTTP production schema, native adapter, compatibility layer,
or test-framework policy is introduced. Removal is a deliberate pre-release API
break. The owner authorizes PR publication on 2026-10-06. Required CI and a
separate explicit merge request govern integration; no later unit is started
by this approval.

## Claim and consumption amendment — 2026-10-06

The owner approves removing terminal/open projection from the claim API and
using `consumeNext()` and `claim.markConsumed()`, with consistent claimed/consumed
vocabulary in APIs, reports, and verification. This explicitly supersedes the
initial DD19 completion projection and DD05's opt-in terminal-completion check.

- **Claimed** means exclusively assigned to an operation. A claim is never rolled
  back, including after cancellation, mismatch, or abandonment.
- **Consumed** means the system acknowledges that all behavior in the record has
  been replayed. It does not mean the underlying operation has terminated.
- `claim(matching:using:)` always starts unconsumed. `markConsumed()` acknowledges
  replay already performed; it neither performs replay nor chooses a continuation.
- `consumeNext()` atomically claims and consumes the next available record. Use
  it only when returning the recorded value constitutes its entire replay.
- `allRecordsClaimed` and `allClaimedRecordsConsumed` are separate opt-in
  evaluations. The former honors `allowsUnclaimedReplayRecords`; that waiver
  never exempts a claimed record from the latter. An unclaimed record is outside
  the second check, so callers may request both checks.
- Open recordings receive no exemption. A location session with three recorded
  updates is consumed after replay reaches the open horizon following those
  updates; its subscription may stay open. HTTP likewise acknowledges an open
  leaf only when traversal reaches it with the domain's required timing and
  decisions satisfied. Core cannot derive this from a queue becoming empty.
- Progress is monotonic; consumption acknowledgement is idempotent and prevents
  further progress. In-flight acknowledgements remain accepted while execution
  quiesces, until lease closure freezes the report. Later updates return false.

The API migration removes `ReplayCompletion`, the completion projection, and
`ReplayClaimUsage.Conclusion`; `isConsumed` replaces the latter. `claimNext()`
becomes `consumeNext()`, and `complete()` becomes `markConsumed()`.
`allRecordingsUsed` becomes `allRecordsClaimed`, while
`allSelectedRecordingsCompleted` becomes `allClaimedRecordsConsumed` with the
new semantics above. Report collections/counts, evaluation failures, and the
leftover policy use claimed/unclaimed or consumed/unconsumed explicitly.
All claimed records appear in the report, including synchronous consumption.
No compatibility aliases or persisted schema changes are introduced.
