# Decision 20: System definitions and pure passthrough

- Status: Accepted
- Recorded: 2026-10-10
- Approved by owner: 2026-10-10
- Authority: The owner accepts pure passthrough and a single protocol-based
  system-authoring boundary, and requests Plan 003 units Fa01 and Fa02 before
  Location. This records the design and implementation handoff; it does not
  mark either implementation complete or authorize starting both together.
- Reconciles: Decisions 2, 5, 10, 12–19 as specified below.
- Delivery: [Plan 003, Phase Fa](../plans/003-clean-slate-implementation.md#phase-fa--passthrough-and-system-authoring).
- Implementation guidance: [Fa01/Fa02 handoff](../plans/003-Fa-system-authoring-handoff.md).

## Pure passthrough

Passthrough provides the ordinary live dependency with its native behavior,
copying semantics, concurrency requirements, and lifetime. Diorama selects the
mode and supplies the typed dependency, but does not wrap its operations in an
execution admission check, serialize them, record them, apply continuation
policies, or diagnose their use after finalization.

An escaped passthrough dependency remains usable according to its normal live
contract. Finish releases the execution's references. It does not invalidate that
dependency, stop its subscriptions, cancel its operations, or wait for its live
work. The consumer owns explicit shutdown where the live API requires it.
Live work may therefore continue across scenario teardown, without Diorama
diagnosing it. Ordinary live resource and thread-safety obligations still apply.

For Random, returning an injected value-type generator directly means copies
advance independently. Diorama no longer imposes shared reference semantics in
passthrough. Reference-type sources retain their native shared behavior. Date
returns live dates after finish, with no frozen last value or epoch fallback.
Record and replay retain their existing shared state and closed-handle behavior.

Passthrough creates no recording/replay track leases and runs no track-content
preparation, normalization, validation, or merge policy. Identity, registration,
and configuration checks necessary to construct the selected live dependency
remain. Record/replay-only capability restrictions must not be imposed on the
passthrough dependency. A future URLSession passthrough is an uninstrumented
session and may support native operations outside Diorama's record/replay scope.

The selected live factory runs during activation, after all attachments finish
preparation. The dependency is exposed only after successful startup. A throwing
factory must clean up its partial construction. On a later startup failure,
Core releases its references to dependencies already constructed; native
construction must account for self-retaining work that reference release alone
cannot clean up. Establish that rollback mechanism at the native adapter gate;
the direct factory signature does not prove it. This does not give Core
authority to cancel separately consumer-owned resources.

Persistence and reporting remain independent of this runtime simplification:

- File decoding, version checks, registration dispatch, strict standalone
  decoding, and startup membership reconciliation keep DD07/DD08/DD18 semantics.
  Skipping runtime content policies does not bypass the persistence decoder.
- Configured passthrough baseline content survives mixed-mode re-recording
  unchanged. It is preserved as immutable scenario data, independent of leases.
- Reports retain the ordered per-track passthrough usage disposition. There are
  no new record, claim, consumption, or post-finish misuse facts for live calls.
- Record/replay attachments and the execution-owned clock/scheduler retain
  their finalization, offline replay, and diagnostic contracts.

## One public system-authoring boundary

`DioramaCore.SystemDefinition` is the supported public way to implement a
system. It describes reusable setup, not one running execution. It declares a
common `Dependency: Sendable`, distinct record and replay state types, system
identity, optional persistence capabilities through the existing descriptor,
and typed track requirements. `Dependency` may be a protocol existential or a
concrete type such as `URLSession`; it need not conform to a new Diorama protocol.

Core derives the attachment layout from those declarations, prepares typed
leases, and offers an optional read-only system validation hook before any
activation. A declaration includes its stable track key, value/header types,
prepared initial content, policies, and optional merge behavior. System code
retrieves prepared tracks and leases through the same typed declarations,
without repeating string IDs, casts, or runtime type matching. Necessary type
erasure remains inside the heterogeneous Core boundary.

Record and replay each have two named activation methods: one constructs that
mode's state from a scoped context, and one receives the Core-owned
`SystemRuntime<State>` and constructs the application dependency. Preparation
does not manufacture deferred state-construction closures. Core creates fresh
state per execution and keyed instance. Passthrough has one direct dependency
factory, with no `PassthroughState`, managed runtime, or state factory.

`SystemRuntime` protects the entire mutable working state, including replay
control state; it is not limited to scalar reads or a live-source wrapper. Core
owns operation admission, synchronous serialization, safe diagnostic delivery,
owned-work cancellation/drainage, rollback, and automatic release of active
record/replay resources. Systems define domain behavior and continuation values.
No separate public closed-state associated type is required. Small detached
snapshots may retain the values a system needs after closure without retaining
live sources, leases, callbacks, or recordings.

Protected operations use a scoped, nonescaping operation token for Core
services. They must not reenter a runtime, call arbitrary consumer callbacks,
suspend, wait for finish, or leak active-resource aliases. Core must retain
diagnostic facts before notification, then call sinks after unlocking. The
same rule applies to conversion failures and throwing operations. Registered
work and cancellation callbacks must not begin inside the protected operation.

The supported path must preserve existing public-only capabilities: immediate
and incremental capture, safe finalization-time freeze, preparation, selection,
claims and consumption, execution time and scheduling, diagnostics, merge,
optional persistence, and cleanup outcomes. Migrating current external-system
proofs is required before retiring the old public path. Raw services must not
be exposed in a way that recreates notification-under-lock or freeze reentry.

`PreparedSystem`, `ActivatedSystem`, the closure-based `ScenarioSystem`
initializer, and superseded preparation/state-owner entry points become
internal where Core still needs them, or are removed where redundant. They are
not retained as an alternative public authoring API. Public-only proofs must
not gain `@testable` imports to complete this migration. Low-level Core tests
may continue to inspect internal startup machinery.

## Native adapter follow-up

This decision does not require a complete native lifecycle abstraction before
the refactor. Location and URLSession must establish their actual construction,
invalidation, isolation, and callback-drainage requirements when their adapters
are built. Core remains responsible for invoking and awaiting managed cleanup;
systems provide the native actions. Lifecycle APIs may evolve at those gates.

For URLSession, record/replay factories can both return configured `URLSession`
instances. The interception bridge routes tasks to the corresponding managed
state. Its returned native session is the public handle, not an active-state
alias extracted through a protected closure. Returning a concrete dependency
does not itself prove native shutdown, routing release, detached live forwarding,
or replay quiescence. Establish those at I01 and broaden them at I08.

Preserving current execution services and cleanup outcomes is Fa02 work;
proving new native adapter lifecycle requirements is later work. Native
construction/cleanup must be investigated at the beginning of G08 and I01,
rather than deferred until their final conformance units.

## Reconciliation and migration

| Earlier contract | Accepted change |
| --- | --- |
| DD02/DD18 system setup and DD13 external-system proof | Keep heterogeneous keyed setup and typed dependency access; implement systems through `SystemDefinition`. |
| DD05/DD10/DD19 lifecycle diagnostics and resource ownership | Managed guarantees continue for record/replay and execution services. Pure passthrough has native lifetime, no post-finish policy, and no Core cancellation/drainage of consumer-owned live work. |
| DD13 shared reference-semantic random dependency | Preserve it in record/replay; passthrough uses the injected source's native copy semantics. |
| DD15 wall continuation in every mode | Record/replay retain last-date/epoch continuation and diagnosis; passthrough continues live reads. The separate execution clock is unchanged. |
| DD16 live manager cleanup and inert escaped facade | Apply scenario-owned cleanup to recording and replay. Pure passthrough has consumer-owned live lifetime; its native facade still has ordinary isolation and cleanup obligations. |
| DD12/DD17 instrumented passthrough, task exclusions, and session invalidation | Instrumentation, Diorama capability restrictions, and scenario-owned invalidation apply to record/replay. Passthrough uses the normal uninstrumented live session. Accepted record/replay native limitations and replay isolation remain. |
| DD19 system-owned records and shared services | Preserve strict domain records and all existing services; move managed synchronization/notification/lifecycle coordination into Core without inventing domain behavior engines. |
| DD07/DD08/DD18 persistence and baseline membership | No change. Runtime passthrough does not relax standalone decoding or delete configured baseline content. |

Existing consumer systems must migrate to the protocol; compatibility shims and
a parallel public closure API are not required. Tests expecting passthrough
closure diagnostics, frozen values, shared value-generator copies, or forced
resource release must change deliberately. Preserve equivalent record/replay
assertions. Historical evidence remains evidence of the previous contracts.

The benefit is one guided authoring path and substantially less passthrough
machinery. The losses are scenario-scoped control of live passthrough work,
misuse reporting for escaped passthrough dependencies, uniform copy behavior
across modes, and recordability restrictions on native passthrough operations.
The owner accepts those tradeoffs. No dependency, persistence schema, HTTP
record shape, deployment-floor, or automatic test-outcome change is approved.
