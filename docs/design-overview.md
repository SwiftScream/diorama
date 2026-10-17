# Design overview

- Status: Accepted
- Created: 2026-09-05
- Approved by owner: 2026-09-07
- Last reviewed: 2026-10-17
- Scope: Decisions 1 through 21
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

On 2026-10-06, the owner accepts
[Decision 19](design-decisions/19-system-owned-records.md). Systems own strict
record models, lifecycle construction, and delivery. Core supplies typed record
capture/freeze, atomic selection/claims, time, scheduling, diagnostics, and
optional progress reporting. Interaction and subscription are domain concepts,
not required Core record protocols or generic behavior engines.

On 2026-10-10, the owner accepts
[Decision 20](design-decisions/20-system-definitions-and-pure-passthrough.md).
Systems use one public `SystemDefinition` protocol with typed track declarations
and separate record/replay state and dependency factories. Core owns managed
state synchronization and lifecycle, including work and callbacks outside protection.
Passthrough supplies ordinary native behavior without recording or interception.
The execution clock remains execution-owned in all setups.

[Decision 21](design-decisions/21-managed-native-lifecycle.md), as amended on
2026-10-16, groups each mode's ordinary State/Dependency factories and
request-stop and cleanup callbacks in `SystemModeDefinition<State, Dependency>`.
Definitions supply required `record`, `replay`, and `passthrough` properties.
Async callback types permit synchronous and actor-isolated functions; initializer
defaults supply no-op lifecycle behavior and conveniences support Void State.
Factories own failed partial
construction; Core owns successful returns, rollback, and awaited shutdown.
Runtime state views provide locked mutation and tracked native-member access.
Core invokes lifecycle hooks in every mode; each system defines what those hooks
do within its lifecycle contract. Passthrough hooks may preserve a dependency's
continued use after finish. `DioramaRandom` and `DioramaDate` use the default
no-op passthrough hooks, so retained native sources remain usable without Diorama
operation diagnostics. Other systems may stop their native resources through
their hooks and document the resulting dependency lifetime.

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

1. A sequentially reusable `Diorama` final class describes complete runtime
   setup: system declarations, live configuration, modes, policies, identity,
   and optional repository. It admits one execution at a time and retains that
   attempt's completed report; separate instances can run concurrently.
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
6. Systems own their typed records. HTTP operations and location sessions
   retain strict, mutually exclusive conclusions, including an explicit open
   horizon. Random and wall observations remain ordinary sequential values;
   no interaction/subscription wrapper or Core lifecycle protocol is required.
7. A system selects a complete record using domain semantics. The execution
   atomically claims it once; the system privately traverses its lifecycle and
   separately supplies any progress/consumption facts.
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
15. The optional `DioramaDate` system records wall observations. Core separately
    exposes the execution scheduler through a monotonic Swift `Clock`.
16. The optional Apple-only location system supplies async replay and a narrow
    Core Location delegate facade. Consumers receive `CLLocation`; live modes
    retain native objects. Recordings always capture floor and ellipsoidal
    altitude as explicit stable values. Two default-off replay options permit
    a genuine subclass only for opted-in fidelity.
17. An HTTP interaction is one recursive lifecycle tree containing shared
    messages and typed adapter supplements, with mutually exclusive returned,
    failed, and open leaves.

Recording dependencies define their post-closure behavior. Date and Random
retain live sources in the returned dependency and diagnose late reads without
recording them. Location and URLSession retain their explicit shutdown
requirements. Sequential replay uses the track's error, fixed-fallback, or
replay-last policy, including after closure, without live access. Core releases
managed state and has no general runtime snapshot facility. See the
[DD20 lifetime amendment](design-decisions/20-system-definitions-and-pure-passthrough.md#recording-lifetime-and-replay-continuation-amendment--2026-10-11).

## Reconciled tensions

### Track order and matcher-based replay

Decision 1 guarantees stable order within a track. Decisions 4 and 5 do not
discard that order: they allow an interaction matcher to select calls in a
different arrival order, then use recorded order to resolve repeated equivalent
available candidates. Stream emissions and phases within a claimed group still
replay in their semantic order. Stored order is therefore always deterministic,
but not every stored order is an application-call constraint.

### Claiming and consumption

Selection and claim are one atomic action. A claim exclusively reserves a
record and never returns it to the available pool. It starts unconsumed;
`markConsumed()` acknowledges that the system has replayed all recorded behavior.
`consumeNext()` combines both steps for synchronous value delivery.
Leases return stored values, including authorship. Systems translate them into
domain objects and select an error, fixed-fallback, or replay-last policy on
`TrackDefinition`. Direct `consumeNext()` reads reach that policy even after managed
state closes. Retained replay leases keep only their selected continuation,
without live resources or baseline records. Failed reads still diagnose;
continuation creates no record or consumption fact. This preserves the stable-value boundary of the
[DD19 replay conversion refinement](design-decisions/19-system-owned-records.md#system-owned-replay-conversion-refinement--accepted-2026-10-07)
under [DD20's managed-state ownership](design-decisions/20-system-definitions-and-pure-passthrough.md).

`allRecordsClaimed` and `allClaimedRecordsConsumed` evaluate these independent
facts only when requested. Open recordings must reach their recorded horizon
before consumption is acknowledged, while their simulated operations can remain
open. Cancellation does not release or automatically consume a claim. Core
reports progress and consumption without interpreting terminal/open lifecycle
semantics. See [DD19's amendment](design-decisions/19-system-owned-records.md#claim-and-consumption-amendment--2026-10-06).

### Location access barriers and record boundaries

Location access remains one ordered state machine, stored as an initial
observation segment followed by one record per authorization-request barrier.
Each segment owns notifications until the next barrier. Observation registration
claims the initial segment; only a matching request at the reached barrier may
claim the next one. Early or wrong requests cannot skip it. Unrequested request
segments remain unclaimed records; current-state reads and individual notifications
do not consume separate records. This preserves DD16's unused-request facts
without making all internal lifecycle events Core consumption units.

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

### Diagnostic observation

[Decision 5's final-report-only amendment](design-decisions/05-consumption-and-verification.md#final-report-only-diagnostics--owner-approved-2026-10-12)
retains diagnostic facts and recording impact immediately without calling user
code. Consumers inspect completed reports; the small reporter exposes no
running snapshot, and late misuse remains in a separate post-finish log.
There are no live sinks, notification queues, or automatic test-failure policy.
Future simple health checks or checkpoint/cursor snapshots are considered
alongside test integration in the [inspection notes](diagnostic-inspection-design-notes.md).
Source ordering, synchronization, cleanup, and replay quiescence still apply.

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
and declare whether unclaimed replay records are acceptable for its attachment.

Core contains track and execution semantic values, system authoring contracts,
and the execution engine. Systems own their strict record schemas, mutable
accumulators, and delivery state machines. Persistence depends on core and
contains schema conversion and storage; repositories load and publish definitions
without activating systems.
System implementations depend on core and may use persistence schema helpers.

`Diorama.execute` supplies a Core-owned `ScenarioExecutionContext` followed by
typed dependencies in declaration order and finalizes the run. Context currently
exposes the shared execution clock; retaining it does not extend run lifetime.
Startup and body errors throw, with finalization and optional publication
completed before the original body error is rethrown. `Diorama.report` stores
the safe completed aggregate on both successful and throwing body exits. A
returned `DioramaResult` stores that same `DioramaReport`, the successful body
value, optional healthy definition, exact optional load outcome, and detailed
publication outcome. `DioramaReport.finalization` holds payload-free diagnostics,
usage, and cleanup facts; `publication` holds safe publication evidence.
`evaluated(...)` checks explicit Core conditions after either body outcome, and
`rendered()` generates text on demand. The retained report owns neither semantic
payloads nor arbitrary errors. See
[DD18's report amendment](design-decisions/18-diorama-setup-and-scenario-data.md#structured-retained-reports--owner-approved-2026-10-15).
The intermediate `DioramaRun` is internal;
the consumer API has no diagnostic sink argument.
Core has no opaque integration-evidence field. Its engine finalization remains
independent of the consumer layer's optional publication responsibility.

### Reusable setup and immutable scenario data

`Diorama` retains its typed systems, execution policies, admission state, and
safe completed report, not a finished execution or its activated dependencies.
It is a final class: references share one admission gate and report. An
overlapping or nested `execute` throws before startup; attempts are not queued.
An admitted attempt clears the previous report, which remains nil until
completion. Startup failure leaves it nil and releases admission after rollback;
the startup error carries its own evidence. Callers inspect or retain a report
before starting the next attempt. The gate does not reserve that report after
execution ends. See [DD18's ownership amendment](design-decisions/18-diorama-setup-and-scenario-data.md#sequential-reuse-and-retained-final-reports--owner-approved-2026-10-12).
Distinct construction paths select no baseline, a supplied
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

`SystemDefinition` declares typed track requirements once. Core prepares their
leases before activation and provides scoped typed lookup to state factories.
The dependency type can be a protocol existential or a concrete native type.
Every mode receives managed state. Passthrough constructs its ordinary live
dependency without track leases or runtime content policies. Strict file decoding
and preservation of configured passthrough baseline data remain independent
requirements. The old public preparation/activation construction path is internal.

Under DD21, startup awaits ordinary State and Dependency factories and publishes
only after all attachments succeed. Core adopts each successful return before
another cancellation check or suspension. Factories clean everything they fail
to return. A failed Dependency factory's already-returned State joins common
rollback after the factory settles.

`execution.state.withLock` serializes short synchronous inout transactions.
`withTrackedValue` admits and counts a scope before selecting a member under
protection, then runs its sync/async body outside the lock. Quiet forms ignore
callbacks before publication and after closure. Native actor isolation remains
Swift's responsibility. Privileged lifecycle contexts expose protected State
without operation effects and expire at hook return.

Normal finalization and rollback close admission, request every system's stop in
reverse order, drain admitted work, and await reverse cleanup. Accepted records
then freeze while State remains available, followed by State/Dependency release
outside locks and candidate/report construction. One Core completion task survives
canceled waiters. Passthrough follows the same hooks; system authors determine
native shutdown and escaped-dependency usability. Independent native HTTP record
forwarding may outlive the observation horizon under DD12.

### Immutable final reports and later diagnostics

`finish()` freezes one result; repeated calls return it unchanged. New misuse
of an escaped managed dependency enters a separately inspectable diagnostic log
without notification. Its small reporter can
outlive the execution without retaining sessions, live sources, recordings, or
scheduling machinery. Escaped replay handles retain only required continuation
state; recording handles may retain live sources under their system contract.
There is no global registry. Retaining a new diagnostic does not restart
replay or weaken quiescent shutdown. Test integrations must respect their test
context's lifetime, not promise to change an already completed test. The
owner-approved amendments in
[Decision 5](design-decisions/05-consumption-and-verification.md#post-finish-diagnostic-retention--2026-09-06)
and [Decision 10](design-decisions/10-lifecycle-and-ownership.md#post-finish-reporting-lifetime--2026-09-06)
define this boundary. The owner-approved
[URLSession invalidation exception](design-decisions/12-urlsession-scope.md#session-invalidation-amendment--2026-09-26)
narrows this promise for instrumented record/replay sessions: they are usable
only during scenario execution and are invalidated at finalization. Creating
new tasks afterward crashes on tested runtimes before interception, so no recoverable Diorama error
or diagnostic is promised for that call. Already running live work may finish
through detached forwarding without retaining the execution.

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
non-HTTP operations in record/replay. DD20 supersedes the former passthrough
restriction: an uninstrumented passthrough session has native capabilities.
Early rejection of an unsupported operation and preservation after a late
conversion failure are different cases.

### Prepared values and final validation

Systems prepare every observation before it enters a working track or domain
accumulator. Core reserves each incremental record before accumulator creation,
freezes constructed accumulators once, and validates complete prepared records.
The system owns transition validity, intentional open horizons, and detachment
of its internal resources. Candidate finalization validates the merged scenario
again.
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

The owner-approved [FoundationNetworking response-disposition exception](design-decisions/12-urlsession-scope.md#foundationnetworking-response-disposition-exception--2026-09-24)
permits record and passthrough to preserve demonstrated native limitations in
response cancellation and pending-decision gating. An interaction that cannot
satisfy the supported disposition model produces a diagnostic and an invalid
recording candidate; the live result remains native. Replay requiring those
unsupported capabilities is rejected at setup. An upstream repair is optional;
explicit task cancellation, offline replay, and correct body delivery remain
required.

The [FoundationNetworking Digest exception](design-decisions/12-urlsession-scope.md#foundationnetworking-digest-exception--2026-09-26)
also preserves native Linux behavior when Digest authentication is unimplemented.
An ordinary 401 with no observed challenge stays an ordinary response; replay
requiring an unsupported Digest challenge is rejected at setup. Native Digest
support is optional for other Linux capabilities. This does not permit custom
authentication replay to escape to live networking.

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

The execution-owned `ContinuousClock` scheduler defines one-to-one playback,
equal-deadline ordering, cancellation, mixed live/replay timing, and quiescent
finalization. Systems determine reachable phases and prerequisites and register
work with domain-appropriate anchors, including current HTTP decisions.
Constant-factor acceleration is the leading next enhancement. Manual advancement, fully virtual time, and user-authored
cross-track constraints remain deferred.

### Initial clock system contract

Status: Resolved by
[decision 15](design-decisions/15-clock-system.md), including its
[execution-clock ownership amendment](design-decisions/15-clock-system.md#execution-clock-ownership-amendment--owner-approved-2026-10-07)
and [date-system naming amendment](design-decisions/15-clock-system.md#date-system-naming-amendment--owner-approved-2026-10-09).
The optional `DioramaDate` attachment records and replays wall observations.
Under [DD15's recording-return amendment](design-decisions/15-clock-system.md#normalized-recording-returns--owner-approved-2026-10-17),
successful recording reads return the same millisecond-normalized absolute
values stored for replay, preserving dependent decisions across a fresh
record/replay cycle. Passthrough remains native; authored overrides remain
intentional transformations applied during finalization.
`DioramaCore` owns the runtime Swift `Clock`, available through executions and
scoped `Diorama` runs without a wall attachment or persisted track. It shares
the execution's scheduler and origin, never records reads or sleeps, and freezes
at the execution horizon while pending sleeps cancel.
Foundation parses ISO 8601 origins into a
`Date`; a representable trailing numeric offset is retained for formatting,
with UTC as the fallback under the 2026-10-02 refinement. The decision also
defines successive signed deltas, authored
overrides, replay exhaustion, scheduler integration, cancellation,
finalization, and portable platform behavior.

The [fixed wall-date range amendment](design-decisions/15-clock-system.md#fixed-wall-date-range-amendment--owner-approved-2026-10-11)
limits rounded wall dates to inclusive Unix seconds
`-62_135_500_000...253_402_250_000`. Production uses fixed numeric comparisons,
independent of display offset; round-trip verification belongs in tests.

### Initial location system contract

Status: Resolved by
[decision 16](design-decisions/16-location-system.md), as narrowed by its
[Apple-only amendment](design-decisions/16-location-system.md#apple-only-location-amendment--owner-approved-2026-10-16)
and revised by its
[native consumer amendment](design-decisions/16-location-system.md#native-consumer-locations-with-opt-in-replay-fidelity--owner-approved-2026-10-17).
The initial Apple-only system defines async replay, a narrow delegate facade,
native `CLLocation` delivery, explicit stable recordings and NSError conversion,
WGS84 route relocation, separate measurement and delivery timing, access-state
request barriers, nonthrowing mismatch behavior, and finalization. Replay
subclassing is limited to opted-in floor or ellipsoidal-altitude fidelity.
Location is not available on Linux.

[DD16's macOS authorization presentation amendment](design-decisions/16-location-system.md#macos-authorization-presentation--owner-approved-2026-10-17)
keeps a recorded `whenInUse` access state in the stable payload. Replay on
macOS presents native `authorizedAlways` for that known state, while iOS
presents `authorizedWhenInUse`; request barriers retain their recorded kind.
Unknown raw values are rejected at the stable-record boundary.

[DD16's coordinate-format amendment](design-decisions/16-location-system.md#regional-and-global-coordinate-formats--owner-approved-2026-10-17)
selects regional east/north meter offsets and global latitude/longitude degree
offsets, both relative to one attachment origin. Origin overrides remain the
only re-record-preserving horizontal edits. Angular relocation retains the
stored degree offsets and reflects pole crossings without promising physical
route geometry. Only the effective origin is persisted; replay and later
origin edits require no original origin or original recording.

Async and delegate consumers receive native errors. Core's package-visible
`NSErrorSnapshot` shares bounded capture, validation, and reconstruction across
Location, URLSession, and future integrations on Apple platforms and Linux.
Systems own preparation, diagnostics, typed supplements, and versioned codecs;
the shared snapshot does not expose a new public error API or schema.

### Consumer-system extension milestone

Status: Resolved by
[decision 13](design-decisions/13-random-proving-system.md).

DD20 makes `SystemDefinition` the single public authoring path, preserving
existing services and public-only proofs while Core manages synchronization,
safe diagnostic retention and all-mode lifecycle. Passthrough hooks determine
native lifetime; empty State and no-op hooks preserve injected dependencies. Native lifecycle integration is proved
with the first applicable adapter, without requiring a universal abstraction.

The random proving system drives the same public system registration, track,
mode, persistence, diagnostic, and finalization boundaries available to a
consumer-defined demand-driven system. Consumer systems use the same public
record, time, scheduling, and reporting services as first-party systems. Synthetic consumers prove that boundary, not
the need for additional generic behavior engines. Arbitrary replacement of the
scenario execution engine remains outside the first milestone.

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
unclaimed-record verification only; it does not bypass persistent registration
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
