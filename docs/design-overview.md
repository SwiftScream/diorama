# Design overview

- Status: Accepted
- Created: 2026-09-05
- Approved by owner: 2026-09-07
- Last reviewed: 2026-09-24
- Scope: Decisions 1 through 18
- Derived from: [Accepted design decisions](design-decisions/README.md)

This document maintains a consolidated reading of the accepted decisions. It
is not an independent design decision and does not override their detailed
contracts. Update it when a later accepted decision changes the combined
architecture.

## Review result

The owner approved the consolidated design and implementation plan on
2026-09-07. The individual decisions retain their accepted status and historical
dates; this approval does not replace their detailed contracts or evidence gates.

The original seventeen decisions established the architecture for plan
synthesis. On 2026-09-19, the owner approved
[Decision 18](design-decisions/18-diorama-setup-and-scenario-data.md), separating
runtime setup from immutable scenario data and refining the persistence and
result boundaries. Its explicit reconciliation governs earlier terminology.
Its 2026-09-20 amendment places optional persistence capabilities on shared
system-type descriptors and permits startup to omit unregistered payload types.
Its 2026-09-21 amendment places consumer setup and run orchestration in a
`Diorama` module above separate core and persistence modules.

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
2026-09-24 [routing amendment](design-decisions/12-urlsession-scope.md#task-ownership-routing-amendment--2026-09-24)
selects native task ownership for per-session execution routing, replacing the
unsuccessful configuration-header route without changing the later capability
and lifecycle gates. The same day's
[native rejection amendment](design-decisions/12-urlsession-scope.md#native-rejection-errors-amendment--2026-09-24)
permits native cancellation errors for excluded Apple stream and WebSocket
tasks, accompanied by adapter diagnostics, and native Linux WebSocket refusal
before interception on a tested profile. Every excluded operation must still
be stopped before live access. The owner-approved
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

1. A reusable `Diorama` describes complete runtime setup: system declarations,
   live configuration, modes, policies, identity, and optional repository.
   An immutable `ScenarioDefinition` contains attachment identities and their
   prepared recorded tracks, independent of runtime configuration.
2. Starting a `Diorama` creates a concurrency-safe scenario execution that
   owns all mutable state for one bounded run. Its configured systems determine
   membership; unconfigured baseline attachments are diagnosed and omitted.
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
10. In-memory recording and replay are first-class workflows over the same
    strict `ScenarioDefinition`. File-backed setup loads once per execution,
    before activation. Finalization produces a new healthy definition and may
    atomically publish it; publication failure does not discard valid semantic
    output or mutate the starting definition.
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

### Body outcome and candidate health

A scoped body returning, throwing, or being canceled does not alter the
setup's publication policy. It always remains visible alongside the final
result. Recording, grouping, merge, and semantic validation determine whether
there is a complete, healthy resulting definition. Optional publication also
requires successful encoding, staging, and commit. A persistence failure retains
the valid semantic output while reporting that publication failed. This keeps
fixture generation independent of test-framework outcome while preserving the
previous publication whenever replacement cannot succeed.

### Consumer and implementation modules

Consumers import `Diorama` together with their selected system modules.
`Diorama` depends on `DioramaCore` and `DioramaPersistence` and owns baseline
selection, startup, scoped execution, and optional publication orchestration.
Setup takes a string scenario ID and default mode directly; file-backed setup
accepts an absolute local file URL. It does not re-export every declaration from
either module. Returned system instances pass directly to setup without a caller
import of core; system authors and callers naming or constructing lower-level
semantic values import core. Each configured system may override the default mode
and declare whether unused replay records are acceptable for its attachment.

Core contains semantic values, system authoring contracts, and the execution
engine. Persistence depends on core and contains schema conversion and storage;
repositories load and publish definitions without activating systems.
System implementations depend on core and may use persistence schema helpers.

`Diorama.execute` supplies dependencies and finalizes the run. Startup and body
errors throw, with finalization awaited before a body error is rethrown. A
returned `DioramaResult` holds the successful body value, finalization facts,
and concrete optional load outcome. The intermediate `DioramaRun` is internal;
the consumer API has no diagnostic sink argument.
Core has no opaque integration-evidence field. Its engine finalization remains
independent of the consumer layer's optional publication responsibility.

### Reusable setup and immutable scenario data

`Diorama` retains its typed systems and execution policies, not an execution or
its dependencies. Distinct construction paths select no baseline, a supplied
definition, a file, or a custom repository. File setup performs no I/O at
construction; every execution loads its own fixed semantic baseline. A supplied
definition is already fixed and reusable. Finalization constructs a new
definition, preserving configured replay/passthrough content, replacing record
content under system merge rules, and omitting unconfigured attachments.

Each `ScenarioSystem` refers to a shared `ScenarioSystemType` containing stable
identity and optional capabilities. Several keyed instances share that metadata.
`SystemTypeID` remains the stable value used in semantic data; the descriptor
and its implementations stay in runtime setup. Ordinary system instances serve
both in-memory and persistent constructors.

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
Codecs accept and return `ScenarioDefinition` directly; a separate public
`PersistedScenario` is unnecessary. Deliberate schema helpers remain inside
persistence, and the core definition does not acquire a `Codable` requirement.
A definition can be semantically valid without being persistable.

Core may declare optional format-neutral persistence protocols without requiring
systems to implement them or consumers to use them. File setup collects codecs
from its configured system types. One decoder uses the registry for dispatch:
standalone decoding rejects unknown types; execution startup skips their payloads
and retains headers for diagnosis and membership reconciliation. No attachment-ID
selection enters the codec. All registered types still decode every instance,
including inactive keys. Unknown payloads remain opaque, while the envelope,
headers, duplicate attachment keys, and JSON syntax remain validated throughout
the document. An unknown type occupying a configured key is an incompatible
baseline, never a source of synthesized replay content.

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

Persisted values are also already prepared. System readers decode their
deliberate schemas and validate the resulting prepared representations before
admission, but do not rerun capture canonicalization, redaction, or
normalization. A load failure returns to startup orchestration for reporting in
the real scenario context.

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

### Unmatched loaded attachments and persistence registration

The repository decodes and validates every payload for persisted-value
admission before comparing the loaded attachment set with current setup. An
unknown system or malformed payload therefore remains a load failure even when
its attachment would not be configured. After successful loading, each
unmatched attachment produces a safe diagnostic and is discarded from execution
and future candidate construction. A later healthy publication may remove it
from the Git-backed scenario file. Ignoring a configured attachment affects
unused-recording verification only; it does not bypass persistent registration
or schema and prepared-value validation.

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
