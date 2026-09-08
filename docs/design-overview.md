# Design overview

- Status: Accepted
- Created: 2026-09-05
- Approved by owner: 2026-09-07
- Last reviewed: 2026-09-09
- Scope: Decisions 1 through 17
- Derived from: [Accepted design decisions](design-decisions/README.md)

This document maintains a consolidated reading of the accepted decisions. It
is not an independent design decision and does not override their detailed
contracts. Update it when a later accepted decision changes the combined
architecture.

## Review result

The owner approved the consolidated design and implementation plan on
2026-09-07. The individual decisions retain their accepted status and historical
dates; this approval does not replace their detailed contracts or evidence gates.

The seventeen accepted decisions describe one coherent architecture. No direct
contradiction requires an accepted decision to be reopened before plan
synthesis.

The original review of decisions 1 through 12 identified scheduler, clock,
location, consumer-extension, and HTTP-composition prerequisites. Decisions 13
through 17 have now resolved them. The synthesis gate for a clean-slate
implementation plan is therefore satisfied, while the required platform and
URLProtocol spikes remain evidence-producing implementation tasks.

The [approved implementation plan](plans/003-clean-slate-implementation.md) records
the review units and remaining evidence-dependent implementation gates.
Decision 12's owner-approved
[planning-order clarification](design-decisions/12-urlsession-scope.md#planning-order-clarification--2026-09-06)
permits provisional production task planning before URLProtocol spikes run;
their results must be reviewed and the affected breakdown confirmed or revised
before production work depends on that boundary. The owner-approved
2026-09-09 [deployment-policy amendment](quality-gates-and-ci.md#apple-deployment-minima--owner-approved-amendment-2026-09-09)
sets iOS 18 and macOS 15 minima so the core can use `Synchronization.Mutex`
directly on Apple and Linux. It supersedes the 2026-09-06 clock-driven floors
without expanding advertised platform or adapter support.
Decisions 5 and 10 now resolve post-finish diagnostics through a separately
retained reporter without changing the immutable final report, as reconciled
below. The plan's separate approval does not bypass its per-unit scope
confirmation, review checkpoints, or remaining evidence gates.

The accepted decisions remain the source of truth. The interpretations below
prevent apparent tensions from being resolved differently during plan
synthesis or implementation.

## Consolidated architecture

The decisions combine into this design:

1. A reusable immutable scenario definition describes identity, repository,
   policies, attachments, and their effective modes.
2. Starting a definition creates a concurrency-safe scenario execution that
   owns all mutable state for one bounded run.
3. Each setup-keyed system attachment owns one or more independently ordered,
   typed tracks. Several instances of the same system can be attached under
   different keys.
4. The scenario supplies record, replay, and passthrough modes with whole-system
   overrides. Replay never contacts a live dependency.
5. Native values remain inside adapters. Only prepared, stable semantic values
   enter tracks, matching, diagnostics, resources, or persistence.
6. Interactions, streams, and clocks use behavior-appropriate grouped
   recordings. Every interaction or subscription has one explicit conclusion,
   including an open-at-recording-horizon case.
7. A system selects a grouped recording using domain semantics. The execution
   atomically claims the selected group once, while its internal lifecycle
   remains private to that claim.
8. Systems retain monotonic relative timing only where elapsed time affects
   replay behavior. Initial replay maps logical duration one-to-one to monotonic
   real duration.
9. Verification and diagnostics report facts. The core does not decide whether
   a test passes; opt-in evaluation helpers and testing integrations do that.
10. The strict in-memory scenario is authoritative. Optional persistence loads
    it once and atomically publishes one complete, healthy candidate at
    finalization.
11. Persisted scenarios have independently versioned Diorama envelopes and
    system payloads, deliberate `Codable` schemas, and deterministic UTF-8 JSON
    in the initial file repository.
12. `DioramaHTTP` owns shared HTTP messages and policies using Swift HTTP Types
    in memory. URLSession adds native lifecycle semantics through one public
    system backed by tested Apple Foundation and FoundationNetworking bridges.
13. A small sequential random system proves the public consumer-system boundary
    before scheduler or platform-adapter complexity is introduced.
14. One execution-owned scheduler maps logical delays one-to-one to
    `ContinuousClock`, orders equal deadlines deterministically, and guarantees
    quiescent shutdown.
15. The optional clock system separates recorded wall observations from a
    scheduler-backed monotonic Swift `Clock`.
16. The optional location system supplies a portable async domain and replay
    model plus an Apple-only Core Location recorder and narrow delegate facade.
17. An HTTP interaction is one recursive lifecycle tree containing shared
    messages and typed adapter supplements, with mutually exclusive returned,
    failed, and open leaves.

## Reconciled tensions

### Track order and matcher-based replay

Decision 1 guarantees stable order within a track. Decisions 4 and 5 do not
discard that order: they allow an interaction matcher to select calls in a
different arrival order, then use recorded order to resolve repeated equivalent
available candidates. Stream emissions and phases within a claimed group still
replay in their semantic order. Stored order is therefore always deterministic,
but not every stored order is an application-call constraint.

### Selection, use, and completion

Selection and claim are one atomic action. A claimed group is used immediately,
including an open group or one whose later replay delivery is stopped. It never
returns to the available pool. Lifecycle progress and whether the recorded
conclusion was reached remain reportable facts, but they are not separate
consumption units and do not implicitly verify caller cancellation.

### Open conclusions and cancellation

`openAtRecordingHorizon` is an explicit recording conclusion, not a dependency
terminal event and not a missing field. It represents observation ending while
work remains active. Caller cancellation is ordinary runtime control and is not
persisted or asserted. A domain-emitted cancellation failure or a decision such
as an authentication-challenge disposition may still be recorded when it is
observable dependency behavior.

### Operation failure and test failure

A replay miss, ambiguity, exhaustion, incompatible continuation, or conversion
problem is a Diorama infrastructure failure. It is recorded immediately and is
also returned through the native operation's failure channel where one exists.
That does not mean the core fails the enclosing test. Testing integrations and
explicit report evaluators decide which diagnostics become test issues.

### Immutable final reports and later diagnostics

`finish()` freezes one result; repeated calls return it unchanged. New misuse
of an escaped dependency enters a separately inspectable diagnostic log before
sink notification, even without an installed sink. Its small reporter can
outlive the execution without retaining sessions, live sources, recordings, or
scheduling machinery; escaped handles also retain only their required frozen
state. There is no global registry. New diagnostic notification does not restart
replay or weaken quiescent shutdown. Test integrations must respect their test
context's lifetime, not promise to change an already completed test. The
owner-approved amendments in
[Decision 5](design-decisions/05-consumption-and-verification.md#post-finish-diagnostic-retention--2026-09-06)
and [Decision 10](design-decisions/10-lifecycle-and-ownership.md#post-finish-reporting-lifetime--2026-09-06)
define this boundary.

### Strict semantic values and tolerant files

The in-memory scenario always has one valid interpretation. A versioned
persisted schema may deliberately accept more than one editing form, such as an
observation alongside an authored override. Decoding selects the effective
override and discards the observation before admitting the strict value.
Canonical writing emits only the selected form. This narrow tolerance does not
weaken rejection of unknown fields or unsupported schema versions.

### Optional persistence and `Codable`

Persistence is optional for the scenario core, so an in-memory consumer system
need not be `Codable`. `Codable` is nevertheless the only initial extension
mechanism for tracks that are persisted. Every track included in a publication
must have a registered persistent system type; resource references can be
`Codable` without requiring their bytes to be resident in the semantic graph.

### Recording failures and unsupported operations

The general conversion rule preserves live application behavior when an
unexpected value cannot be represented after a supported operation has begun,
while making the candidate unhealthy. A concrete adapter may define an earlier,
stricter boundary for operations it does not support at all. Decision 12 does
this for URLSession upload, download, streaming-body, WebSocket, stream, and
non-HTTP operations, including in passthrough mode. Early rejection of an
unsupported operation and preservation after a late conversion failure are
different cases.

### Prepared values and final validation

Systems prepare every observation before it enters a working track. Candidate
finalization then validates the complete grouped and merged scenario again.
The latter is not a second opportunity to redact raw values; it verifies
cross-record invariants, authored-override merges, resource integrity, and
publication health using values that are already prepared.

### Shared HTTP and native adapter behavior

Swift HTTP Types provide in-memory HTTP currency values, while Diorama owns its
body, lifecycle, redaction, matching, and persisted schema. Redirect policy,
authentication callbacks, native errors, and delivery mechanics remain adapter
semantics. Decision 17 embeds those typed supplements in the lifecycle node they
refine rather than using a companion track. Sharing HTTP values therefore does
not imply that arbitrary recordings can move between different client
libraries.

### Exact bodies and editable delivery profiles

Exact body bytes remain authoritative even when a JSON media type is stored in
a readable `.json` resource. Body segments store observed byte counts as
weights. An unchanged body reproduces exact boundaries; an edited body scales
them deterministically and cannot make the runtime profile out of range. Only a
`Content-Length` proven equivalent to a complete stored body becomes a derived
field value. Ambiguous lengths and other validators remain literal.

### One URLSession system and two platform bridges

Apple Foundation and FoundationNetworking are separate native implementations,
but they feed one URLSession system and persistence model. Platform capability
profiles describe what each bridge has proved it can reproduce. A scenario is
portable across Apple platforms and Linux only when it uses their common tested
profile. Platform-specific implementation code does not create a second
scenario system identity.

### Attachment keys, system types, and match keys

These identifiers remain distinct:

- an attachment key identifies a configured system instance within a scenario;
- a persistent system type identifies the decoder and schema owner;
- a recording or correlation identifier connects stable lifecycle data;
- a match key is an optional system-internal selection technique;
- URLSession routing state is private execution data and never enters any of
  those stable namespaces.

## Plan synthesis constraints

The original consistency review identified the following prerequisites. Their
resolved sections remain here to make the resulting constraints visible during
plan synthesis. The final section retains a rule that the implementation plan
must preserve explicitly.

### Initial real-time replay scheduler

Status: Resolved by
[decision 14](design-decisions/14-real-time-replay-scheduler.md).

The execution-owned `ContinuousClock` scheduler now defines one-to-one playback,
equal-deadline ordering, phase prerequisites, cancellation, mixed live/replay
timing, and quiescent finalization. Constant-factor acceleration is the leading
next enhancement. Manual advancement, fully virtual time, and user-authored
cross-track constraints remain deferred.

### Initial clock system contract

Status: Resolved by
[decision 15](design-decisions/15-clock-system.md). The optional first-party
clock attachment separates sequentially recorded wall observations from a
runtime-only monotonic Swift `Clock`. The decision defines ISO 8601 origins,
successive signed deltas, authored overrides, replay exhaustion, scheduler
integration, cancellation, finalization, and portable platform behavior.

### Initial location system contract

Status: Resolved by
[decision 16](design-decisions/16-location-system.md). The initial system now
defines portable async replay, a narrow Apple delegate facade, stable location
and NSError conversion, WGS84 route relocation, separate measurement and
delivery timing, access-state request barriers, nonthrowing mismatch behavior,
and finalization. Live location recording remains Apple-only while stable
models and replay remain portable.

### Consumer-system extension milestone

Status: Resolved by
[decision 13](design-decisions/13-random-proving-system.md).

The random proving system drives the same public system registration, track,
mode, persistence, diagnostic, and finalization boundaries available to a
consumer-defined demand-driven system. Consumer systems may compose the initial
behavior engines; arbitrary replacement of the scenario execution engine
remains outside the first milestone.

### HTTP lifecycle composition

Status: Resolved by
[decision 17](design-decisions/17-http-lifecycle-composition.md).

One recursively composed interaction now owns its initial request, response
nodes, exact body content, weighted delivery profile, decisions, continuations,
and mutually exclusive leaf. URLSession-specific redirects, authentication,
response dispositions, and failures are embedded typed supplements. Required
platform capabilities derive from this structure without fragmenting the
shared HTTP schema or URLSession identity.

### Ignored attachments and persistence registration

An intentionally ignored persisted attachment is exempt from unused/unattached
verification, but that does not automatically make an unknown system payload
safe to decode, validate, migrate, or republish. The plan should preserve this
rule: ignoring affects execution verification; it does not bypass persistent
system registration or schema validation. Supporting opaque preservation of an
unregistered payload would be a separate future persistence feature.

## Required implementation evidence

The following matters have accepted semantics but need spikes or executable
proof before broader implementation depends on them:

- Validate per-session URLProtocol interception with a bodyless GET on macOS
  and Linux, then on an iOS simulator.
- Expand the URLSession conformance matrix per platform before advertising
  redirect, authentication, failure, delegate, and lifecycle capabilities.
- Prove adapter quiescence without canceling consumer-owned live work or
  permitting replay callbacks after finalization.
- Select a Swift tools version and compatible Swift HTTP Types release, then
  establish the supported Linux Swift/libcurl CI matrix.
- Prove atomic file replacement and deterministic JSON output; add logical
  multi-file publication only when the first resource-backed value requires it.

Failure of a spike reopens the smallest affected feature boundary. It must not
be hidden by a platform conditional, a live replay fallback, or loss of a
recorded lifecycle phase.

## Deliberately deferred features

The implementation plan should not accidentally pull these into the initial
milestone:

- manual or immediate logical-time playback;
- explicit cross-track ordering constraints;
- scenario-scoped named values and pseudonym assignment;
- semantic JSON canonicalization and structured JSON matching;
- reusable recordings and cardinality ranges;
- multi-path continuation trees;
- arbitrary custom behavior engines beyond the confirmed extension milestone;
- cross-client HTTP portability before a second adapter proves it;
- URLSession upload, download, WebSocket, stream, cache, metrics, progress,
  platform-security challenge, and background-session behavior;
- optimistic concurrent publication, recording-duration locks, or general
  migration tooling.

## Conclusion

The accepted decisions are consistent at their current level of abstraction.
They define the core invariants, data boundaries, failure rules, persistence
posture, proving system, scheduler, clock, location, shared HTTP domain, and
URLSession lifecycle well enough to synthesize the clean-slate implementation
plan. Evidence-producing implementation spikes may narrow an advertised
platform capability, but they must not silently weaken these semantics.
