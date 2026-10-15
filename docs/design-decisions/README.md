# Design decision index

- Status: Accepted
- Consolidated design approved by owner: 2026-09-07

On 2026-10-16, the owner approves
[DD21's typed mode definitions amendment](21-managed-native-lifecycle.md#typed-mode-definitions--owner-approved-2026-10-16).
`SystemDefinition` requires `record`, `replay`, and `passthrough` declarations of
`SystemModeDefinition<State, Dependency>`, grouping construction and shutdown
callbacks with lifecycle defaults and Void-State convenience initializers.
The state-owned lifecycle and application-consumer contracts remain unchanged.

This index tracks decisions produced through the completed
[design decision process](../plans/001-design-decision-process.md) and
[follow-up process](../plans/002-follow-up-design-decisions.md). No decision is
accepted without explicit owner approval. Each decision may contain smaller
review questions resolved during its discussion.

The owner reaffirmed approval of all seventeen decisions and their recorded
amendments on 2026-09-07, together with the consolidated
[design overview](../design-overview.md). Individual decision dates remain
historical records; no architectural contract changes with this status update.

On 2026-10-12, the owner approves
[Decision 5's final-report-only amendment](05-consumption-and-verification.md#final-report-only-diagnostics--owner-approved-2026-10-12),
explicitly reconciling Decisions 10 and 20. Remove live diagnostic callbacks and
public running-ledger inspection; preserve completed reports, immediate fact
retention, publication health, and separate post-finish logs. Consider future
health checks and snapshots alongside test integration.

On 2026-10-12, the owner approves
[Decision 18's sequential reuse and retained-report amendment](18-diorama-setup-and-scenario-data.md#sequential-reuse-and-retained-final-reports--owner-approved-2026-10-12).
`Diorama` becomes a final class that rejects overlapping executions, supports
sequential reuse, and stores a completed report before returning or rethrowing
the original body error. This consumer ownership change preserves independent
Core executions and the existing publication-health policy.

On 2026-10-15, the owner approves
[DD18's structured retained-report amendment](18-diorama-setup-and-scenario-data.md#structured-retained-reports--owner-approved-2026-10-15).
`DioramaResult` preserves caller-owned outputs; `DioramaReport` shares structured
finalization and safe publication evidence after either body outcome, with
explicit evaluation and rendering on demand.

On 2026-10-10, the owner accepts
[Decision 20: System definitions and pure passthrough](20-system-definitions-and-pure-passthrough.md).
Passthrough provides ordinary live behavior and consumer-owned lifetime;
`SystemDefinition` becomes the sole public authoring path, with Core-owned
record/replay state and lifecycle. Its reconciliation governs earlier all-mode
closure, Random copy-semantics, and instrumented-passthrough requirements.
Plan 003 Fa01/Fa02 deliver these changes before Location; native lifecycle
integration remains a gate at the first applicable adapter work.

On 2026-10-11, the owner selects
[Decision 21: Managed native lifecycle](21-managed-native-lifecycle.md).
Async activation, explicit resource handles, same-name sync/async scoped access,
and awaited resource finalization extend DD20. State types remain ordinary
Sendable types. The decision also specifies temporary passthrough construction
ownership while preserving consumer-owned lifetime after successful startup.

On 2026-10-15, the owner approves implementation of
[DD21's state-owned lifecycle amendment](21-managed-native-lifecycle.md#state-owned-lifecycle--owner-approved-2026-10-15).
All modes have ordinary State/Dependency factories and definition-level stop and
cleanup hooks. Runtime state views replace resource handles; lifecycle access
expires after each hook. This reconciles DD10, DD19, and DD20: Core invokes
lifecycle hooks in every mode, including passthrough after publication. Each
system defines its hooks' native cleanup behavior and the resulting dependency
lifetime; no-op passthrough hooks can preserve continued use after finish.

On 2026-10-13, the owner approves
[DD21's factory-owned construction amendment](21-managed-native-lifecycle.md#factory-owned-construction--owner-approved-2026-10-13).
Factories own failed partial construction. Core adopts resources only from
successful results, retaining rollback before publication and awaited managed
shutdown. This removes the pre-factory ledger and passthrough construction context.

On 2026-09-19, the owner approved Decision 18 during the C04/C04A API review.
It separates reusable `Diorama` setup from immutable `ScenarioDefinition` data
and makes persistence operate directly on that shared in-memory model. Its
explicit reconciliation supersedes the earlier configuration meaning of
"scenario definition" in Decision 10; other earlier records retain their history.

On 2026-09-20, the owner approved Decision 18's amendment introducing shared
system-type capabilities and registry-based unknown-payload omission at startup.
Complete standalone decoding remains strict; see the amendment for its explicit
reconciliation with the earlier registration and validation rules.

On 2026-09-21, the owner approved Decision 18's consumer-module amendment:
`Diorama` owns setup and run orchestration above core and persistence, with
concrete load outcomes and one scoped result API.
The same review later narrowed the consumer import boundary, replacing
whole-module re-exports with explicit setup arguments and inferred system values.

On 2026-09-24, the owner approved [Decision 12's routing amendment](12-urlsession-scope.md#task-ownership-routing-amendment--2026-09-24):
the production URLSession adapter identifies execution ownership through native
task identity and the adapter-owned session lease, without HTTP routing fields.

The owner also approved [Decision 12's native rejection amendment](12-urlsession-scope.md#native-rejection-errors-amendment--2026-09-24)
on 2026-09-24: Apple stream and WebSocket rejection pairs an adapter diagnostic
with native cancellation, and pre-interception Linux WebSocket refusal may
retain its native error on a tested profile with no network access.

On the same date, the owner approved the FoundationNetworking
response-disposition exception in [Decision 12](12-urlsession-scope.md#foundationnetworking-response-disposition-exception--2026-09-24)
and [Decision 17](17-http-lifecycle-composition.md#foundationnetworking-response-disposition-exception--2026-09-24).
Diorama may preserve the demonstrated native live limitation without requiring
an upstream repair, while keeping recordings truthful and rejecting replay
that requires unsupported response decisions.

On 2026-09-26 the owner approved the FoundationNetworking Digest exception in
[Decision 12](12-urlsession-scope.md#foundationnetworking-digest-exception--2026-09-26)
and [Decision 17](17-http-lifecycle-composition.md#foundationnetworking-digest-exception--2026-09-26).
Preserve the demonstrated native 401 response without manufacturing a Digest
challenge. Reject replay requiring unsupported Digest capability at setup;
custom Basic challenge decisions and offline replay still require conformance.

On 2026-09-26 the owner approves the native session invalidation amendment in
[Decision 12](12-urlsession-scope.md#session-invalidation-amendment--2026-09-26)
and [Decision 17](17-http-lifecycle-composition.md#session-invalidation-amendment--2026-09-26),
reconciled with [Decision 10](10-lifecycle-and-ownership.md#native-urlsession-lifetime-exception--2026-09-26).
The returned URLSession is usable only during scenario execution; creating new
tasks afterward crashes on the tested native runtimes. No recoverable error or
diagnostic is promised before interception can run. Existing live tasks may
finish through detached forwarding; replay still requires native quiescence.

On 2026-10-07, the owner approves [Decision 15's execution-clock ownership
amendment](15-clock-system.md#execution-clock-ownership-amendment--owner-approved-2026-10-07):
`DioramaCore` owns the runtime Swift `Clock`, exposed by executions and scoped
consumer runs independently of wall attachments. `DioramaClock` retains wall
recording and replay. The amendment explicitly reconciles DD02, DD14, DD18,
and DD19 and revises F06/F07 without changing wall schemas.

On 2026-10-08, the owner approved [Decision 18's execution-context amendment](18-diorama-setup-and-scenario-data.md#execution-context-amendment--owner-approved-2026-10-08)
during F06 review. One scoped `execute` body always receives a Core-owned
`ScenarioExecutionContext` before its typed dependencies. The context initially
exposes the execution clock without extending execution lifetime.

On 2026-10-09, the owner approves [Decision 15's date-system naming
amendment](15-clock-system.md#date-system-naming-amendment--owner-approved-2026-10-09):
`DioramaDate`, `DioramaDateSystem`, and `DioramaDateSource` replace the wall
system's former clock names, including the persisted type `diorama.date`.
The payload remains version 1; former imports and identifiers have no aliases
or automatic migration.

On 2026-10-11, the owner approves [Decision 15's fixed wall-date range
amendment](15-clock-system.md#fixed-wall-date-range-amendment--owner-approved-2026-10-11):
rounded wall dates use inclusive Unix-second bounds of `-62_135_500_000` and
`253_402_250_000`. Fixed numeric checks replace production format/reparse
validation, with no timezone-dependent date bounds. Round-trip checks remain
in cross-platform tests.

| Number | Decision | Planned file | Status |
| --- | --- | --- | --- |
| 1 | [Common abstraction](01-common-abstraction.md) | `01-common-abstraction.md` | Accepted |
| 2 | [Shared and system-specific semantics](02-shared-vs-system-semantics.md) | `02-shared-vs-system-semantics.md` | Accepted |
| 3 | [Recorded behaviors](03-recorded-behaviors.md) | `03-recorded-behaviors.md` | Accepted |
| 4 | [Replay selection](04-replay-selection.md) | `04-replay-selection.md` | Accepted |
| 5 | [Consumption and verification](05-consumption-and-verification.md) | `05-consumption-and-verification.md` | Accepted |
| 6 | [Runtime-to-snapshot conversion](06-runtime-to-snapshot-conversion.md) | `06-runtime-to-snapshot-conversion.md` | Accepted |
| 7 | [Persistence boundary](07-persistence-boundary.md) | `07-persistence-boundary.md` | Accepted |
| 8 | [Schema compatibility](08-schema-compatibility.md) | `08-schema-compatibility.md` | Accepted |
| 9 | [Normalization and redaction](09-normalization-and-redaction.md) | `09-normalization-and-redaction.md` | Accepted |
| 10 | [Lifecycle and ownership](10-lifecycle-and-ownership.md) | `10-lifecycle-and-ownership.md` | Accepted |
| 11 | [HTTP model strategy](11-http-model-strategy.md) | `11-http-model-strategy.md` | Accepted |
| 12 | [URLSession scope](12-urlsession-scope.md) | `12-urlsession-scope.md` | Accepted |
| 13 | [Random proving system and extension boundary](13-random-proving-system.md) | `13-random-proving-system.md` | Accepted |
| 14 | [Initial real-time replay scheduler](14-real-time-replay-scheduler.md) | `14-real-time-replay-scheduler.md` | Accepted |
| 15 | [Initial clock system](15-clock-system.md) | `15-clock-system.md` | Accepted |
| 16 | [Initial location system](16-location-system.md) | `16-location-system.md` | Accepted |
| 17 | [HTTP lifecycle composition](17-http-lifecycle-composition.md) | `17-http-lifecycle-composition.md` | Accepted |
| 18 | [Diorama setup and immutable scenario data](18-diorama-setup-and-scenario-data.md) | `18-diorama-setup-and-scenario-data.md` | Accepted |
| 19 | [System-owned records and shared execution services](19-system-owned-records.md) | `19-system-owned-records.md` | Accepted |
| 20 | [System definitions and pure passthrough](20-system-definitions-and-pure-passthrough.md) | `20-system-definitions-and-pure-passthrough.md` | Accepted |
| 21 | [Managed native lifecycle](21-managed-native-lifecycle.md) | `21-managed-native-lifecycle.md` | Accepted |

On 2026-10-06, the owner accepts [Decision 19](19-system-owned-records.md):
systems own strict lifecycle records and delivery, while Core supplies typed
record capture, selection, and execution services. Its explicit reconciliation
amends the generic capability requirements in the earlier records. Its
[claim/consumption amendment](19-system-owned-records.md#claim-and-consumption-amendment--2026-10-06)
also separates exclusive claims from acknowledged replay without projecting
terminal/open lifecycle semantics into Core.

On 2026-10-07, the owner approves DD19's
[synchronous replay continuation amendment](19-system-owned-records.md#synchronous-replay-continuation-amendment--accepted-2026-10-07):
systems project stored values into replay output during preparation and opt into
fixed or replay-last continuation without fabricating records or consumption.
The subsequent [replay conversion refinement](19-system-owned-records.md#system-owned-replay-conversion-refinement--accepted-2026-10-07)
supersedes preparation-time projection: leases return stored values, systems
translate them, and continuation operates on the stored type.

The initial twelve decisions and their combined
[design overview](../design-overview.md) establish the architecture and
URLSession direction. Follow-up decisions 13 through 17 resolve the proving
system, scheduler, clock, location, and concrete HTTP lifecycle needed before
synthesis of the clean-slate implementation plan.

The 2026-10-11 [DD20 lifetime amendment](20-system-definitions-and-pure-passthrough.md#recording-lifetime-and-replay-continuation-amendment--2026-10-11)
lets each recording system define post-closure behavior: Date and Random retain
live sources with late-call diagnostics, while managed native systems keep their
shutdown contracts. Sequential replay uses public track continuation policies;
the generic runtime snapshot facility is removed.
