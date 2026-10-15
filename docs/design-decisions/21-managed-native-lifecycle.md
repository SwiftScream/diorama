# Decision 21: Managed native lifecycle

> The [state-owned lifecycle amendment](#state-owned-lifecycle--owner-approved-2026-10-15) is the current contract. The resource-handle designs below record its history.

- Status: Accepted
- Created: 2026-10-11
- Approved by owner: 2026-10-11
- Authority: The owner selects explicit resource handles over separated state,
  retains the runtime key-path convenience, agrees to same-name sync/async
  overloads, and requests one Fa implementation work item with consolidated
  solution documentation. This records the design; it does not start implementation.
- Delivery: [003-Fa08](../plans/003-clean-slate-implementation.md#003-fa08--managed-resource-handles-and-actor-owned-lifecycle).
- Trigger: [Fa06 / R5 finding](../plans/003-clean-slate-implementation.md#003-fa06--public-actor-owned-lifecycle-evidence),
  incorporated into the Fa08 review unit.
- Goal: Keep system authoring easy to understand while moving concurrency,
  ownership, rollback, and shutdown ordering into Core.
- Alternatives: [Ownership comparison](../managed-native-lifecycle-options.md)
  records why resource handles are selected over state protocols, base classes,
  separated state, and generated facades.
- Builds on: [DD05](05-consumption-and-verification.md),
  [DD10](10-lifecycle-and-ownership.md),
  [DD12](12-urlsession-scope.md),
  [DD14](14-real-time-replay-scheduler.md),
  [DD16](16-location-system.md), and
  [DD20](20-system-definitions-and-pure-passthrough.md).

## Decision

Keep one `SystemDefinition`, its separate record/replay state and dependency
factories, and synchronous `SystemRuntime.withActiveState`. Make activation
asynchronous and add **explicit registration of managed native resources**.

The author has three responsibilities:

1. Declare stable tracks and validate them, as today.
2. Build mode state. When creating a resource that needs explicit shutdown,
   register it immediately with its two finalization actions.
3. Build the application dependency around managed state and resource handles.

The author creates the resource and registers it before fallible configuration
begins. Core then owns its lifecycle. The same ownership record handles a
throwing factory, later attachment failure, startup cancellation,
and normal finish. Authors supply both lifecycle actions together and do not
write rollback loops or maintain a separate closed flag on each facade. Simple
value systems need no resource registration. An async factory with no explicit
cleanup requirement also needs no registration.

Native resources and semantic state have different access rules. The runtime
continues to serialize short, synchronous state changes. Resource handles admit
native calls and callbacks outside that protection, preserving their actor
isolation. Asynchronous lifecycle support does not make mutable state closures
suspendable.

## Public API contract

These signatures define the implementation contract; the API is not implemented
yet. Existing identity, declaration, validation, and associated-type requirements
remain.

```swift
protocol SystemDefinition: Sendable {
    associatedtype Dependency: Sendable
    associatedtype RecordState: Sendable
    associatedtype ReplayState: Sendable

    func makeRecordState(in context: borrowing SystemStateContext)
        async throws -> RecordState
    func makeReplayState(in context: borrowing SystemStateContext)
        async throws -> ReplayState

    func makeRecordDependency(using runtime: SystemRuntime<RecordState>)
        async throws -> Dependency
    func makeReplayDependency(using runtime: SystemRuntime<ReplayState>)
        async throws -> Dependency

    func makePassthroughDependency(in context: borrowing PassthroughConstructionContext)
        async throws -> Dependency
}
```

Synchronous implementations can still satisfy these async requirements. Random
and Date can keep synchronous factory bodies. An actor-based system can mark
individual factories `@MainActor`; there is no second system protocol, executor
enum, runtime actor identifier, or caller requirement to start on that actor.

`ScenarioExecution.start` becomes `async throws(ScenarioStartupFailure)` for
all configurations. Baseline and repository startup propagate that await.
`Diorama.execute` is already async; its ordinary call site stays the same.
Do not retain a synchronous startup path that blocks waiting for actors, or
choose startup behavior by inspecting which systems happen to be attached.
Cancellation remains part of structured startup failure evidence, including
rollback outcomes, rather than discarding those facts in a bare cancellation
error. Repository startup retains its existing evidence wrapper.

Replace the current `cleanUpRecordState` / `cleanUpReplayState` author hooks with
resource registrations. State itself returns to ordinary Swift ownership after
freeze. Explicit resource shutdown has one owner and one declaration site.
Existing cleanup fixtures migrate to registered resources; this is an intentional
public API change delivered by Fa08.

## Resource registration

A borrowed, noncopyable state context gains:

```swift
func registerResource<Native: Sendable>(
    _ resource: Native,
    didBeginFinalization: @escaping @isolated(any) @Sendable (Native) -> Void,
    willEndFinalization: @escaping @isolated(any) @Sendable (Native) async -> SystemCleanupResult
) -> SystemResource<Native>
```

Each call creates a fresh typed registration in the current attachment's
construction ledger. No resource key, cast, or global lookup is required.
Copies of its `SystemResource` share one admission gate and one lifetime. Native
objects with non-Sendable internals belong inside an actor or global-actor
bridge; the bridge reference can cross this boundary without unsafe annotations.

An overload for `Native: Actor` accepts `(isolated Native) -> Void` for
`didBeginFinalization` and `(isolated Native) async -> SystemCleanupResult` for
`willEndFinalization`, both escaping and Sendable. This lets an ordinary actor
owner express a synchronous begin body without exposing nonisolated mutable
state. Core awaits the actor hop before invoking that body. Global-actor bridges
use the isolation-preserving closure form above. Neither form permits a begin
body that throws or suspends.

Registration is synchronous and nonthrowing, including from an actor-isolated
factory. Core stores the supplied value and both actions before returning its
managed handle. It does not reject registration because the task is canceled,
check cancellation before accepting ownership, or invoke either lifecycle action
inline. The ledger already exists before the state factory runs and does not
depend on that factory returning a state. Rollback waits for the factory to unwind.

The author must register a newly acquired resource before any subsequent throw,
cancellation check, suspension, or other fallible work, including evaluation of
the remaining registration arguments. Constructing it inline with closure-literal
actions makes this ordering clear. Core cannot clean up an unregistered resource.
This author obligation is an explicitly accepted tradeoff for the simpler API.
Registration transfers lifecycle responsibility for an execution-owned resource;
it does not authorize taking ownership of an unrelated consumer-owned object.

Fallible or suspending setup happens afterward through the handle. If a native
API has a throwing initializer, first register a bridge that has no native object,
then initialize it during tracked configuration. An external initializer remains
responsible for resources it acquires and fails to return; Core cannot recover
an object the native API never exposes.

`didBeginFinalization` must initiate shutdown, detach or disable observation
and routing as appropriate, and release owned decision waits needed for progress.
Its body is synchronous and nonthrowing; Core awaits only the hop to its isolation.
It cannot await completion of the work being stopped. Native stop requests may
cause synchronous reentry, so Core invokes them outside every state/ledger lock.

`willEndFinalization` awaits the shutdown acknowledgement and finishes native
release on the proper actor. It returns a small safe outcome, conceptually `.completed` or
`.failed(DiagnosticLabel)`, and does not throw out of the cleanup sequence.
**Every return promises quiescence of Diorama-owned observation and delivery**,
including a failed ancillary cleanup outcome. This does not mean completion of
all consumer-owned native work. Failure to establish the promised quiescence is
not a successfully finished execution.
A resource must continue waiting and may report a safe diagnostic; a timeout
cannot turn ongoing callbacks into safe completion. No general timeout or forced
termination is proposed.

Native wrappers own any execution-scoped tasks necessary to implement these
actions and must join them in `willEndFinalization`. They must not wait for this
execution's `finish`, start new scenario work during shutdown, or depend on a later resource's
finalization action. Resource dependency order must follow registration order,
so reverse finalization can unwind child resources before parents. This is not
a general dependency graph.

### Lifecycle terminology

The existing public execution operation is `ScenarioExecution.finish()`, and
its overall process and result use the term finalization. Current author hooks
are `cleanUpRecordState` / `cleanUpReplayState`; lower-level implementations also
use `stop`, `close`, `quiesce`, and `deactivate`. The registration labels
use event phrasing tied to the established finalization vocabulary:

| Hook | When Core invokes it | Author responsibility |
| --- | --- | --- |
| `didBeginFinalization` | Resource finalization has begun: admission is closed, and Core has not yet waited for admitted work to drain. | Initiate shutdown and unblock owned waits; do not wait for completion. |
| `willEndFinalization` | Admitted work has drained, and resource finalization must complete before Core proceeds. | Await remaining native acknowledgement, release owned resources, and return the cleanup outcome. |

The `did` / `will` distinction follows the actual ordering. The first hook runs
after finalization begins. The second runs before that resource's finalization
ends, and Core awaits its completion. `didEndFinalization` would suggest a
notification after cleanup had finished, which is not this hook's role.
`willBeginFinalization` would suggest an opportunity before admission closes;
the first hook runs after that boundary. These are portable lifecycle
names and introduce no dependency on an Apple framework or delegate protocol.

Both hooks are required actions, not passive notifications. The first has a
synchronous, nonthrowing body; Core may await the hop to its actor. The second
can suspend but returns a safe outcome rather than throwing. Core invokes each
hook at most once per registration and awaits both before declaring normal
finish or startup rollback complete. These are resource lifecycle events,
not a claim that execution startup succeeded or
that the whole scenario has finished when an individual hook returns.

Keep two phases: a single final hook called only after drainage cannot release
a callback that needs a shutdown signal before it can return. Calling every
resource's `didBeginFinalization` before awaiting any drainage preserves that ordering.

## Author example

This excerpt shows the record side of a MainActor system. Replay supplies its
own state and dependency factories with the same pattern and no live source.
`NativeBridge` is a private actor-isolated owner; `ManagerFacade` is the public
application API. Stable recording fields are omitted here.

```swift
struct RecordState: Sendable {
    let native: SystemResource<NativeBridge>
    // Typed leases and stable mutable domain state also live here.
}

@MainActor
func makeRecordState(in context: borrowing SystemStateContext)
    async throws -> RecordState
{
    // Resolve every required typed lease before native construction.
    let native = context.registerResource(
        NativeBridge(),
        didBeginFinalization: { @MainActor bridge in bridge.requestStop() },
        willEndFinalization: { @MainActor bridge in await bridge.close() }
    )
    try await native.perform { @MainActor bridge in
        try await bridge.configure()
    }
    return RecordState(native: native)
}

@MainActor
func makeRecordDependency(using runtime: SystemRuntime<RecordState>) throws
    -> ManagerFacade
{
    let native = try runtime.withActiveState { state, _ in state.native }
    return ManagerFacade(runtime: runtime, native: native)
}
```

Returning the managed resource handle from the state operation is safe: it is a
revocable capability, not an alias to the raw bridge. The dependency factory may
wire callbacks into the registered owner and construct an ordinary facade.
Anything requiring independent shutdown must already have a resource owner from
the state factory. A dependency-factory error unwinds the same ledger.

The facade uses a resource scope for native calls and a separate synchronous
state scope for semantic updates. It does not call the native API while holding
the managed state lock. Pure source operations already allowed by DD20, such as
Random's synchronous source read, keep their existing state operation contract.

## Calls, callbacks, and retained handles

`SystemResource<Native>` exposes two kinds of scoped entry, each with synchronous
and asynchronous overloads of the **same name**:

| Entry | Use | If admission is closed |
| --- | --- | --- |
| `perform` | Application operations; also configuration by the active construction task | Diagnose and throw the closed-lifetime failure before invoking the body. |
| `performIfOpen` | Native observations, callback delivery, and intentionally idempotent late commands | Return an explicit ignored disposition without invoking the body or adding late-callback diagnostics. |

The runtime exposes matching `withResource` and `withResourceIfOpen` conveniences.
Their key paths select **managed handles**, not raw native values:

```swift
// SystemResource<Native>
func perform<Result>(_ body: (Native) throws -> Result) throws -> Result
func perform<Result: Sendable>(
    _ body: @isolated(any) @Sendable (Native) async throws -> Result
) async throws -> Result

// SystemRuntime<State>
func withResource<Native: Sendable, Result>(
    _ keyPath: KeyPath<State, SystemResource<Native>>,
    _ body: (Native) throws -> Result
) throws -> Result
func withResource<Native: Sendable, Result: Sendable>(
    _ keyPath: KeyPath<State, SystemResource<Native>> & Sendable,
    _ body: @isolated(any) @Sendable (Native) async throws -> Result
) async throws -> Result
```

The key-path convenience extracts the typed handle during a short state
operation, leaves state protection, then enters the handle's resource scope.
If finalization wins between those steps, resource admission rejects the call
without invoking the body. Quiet access uses quiet state lookup and quiet
resource entry, with one flattened ignored/performed disposition. Neither form
holds the state lock while running native code, hopping actors, or awaiting work.
Key-path getters follow the same pure, nonreentrant restrictions as state reads.

Both spellings below are supported; the convenience is the usual facade form:

```swift
let resource = try runtime.withActiveState { state, _ in state.native }
try await resource.perform { @MainActor native in try await native.configure() }

try await runtime.withResource(\.native) { @MainActor native in
    try await native.configure()
}
```

The overloads differ in their closure parameter types as well as in `async`.
With the checked Swift 6.4 signatures, a synchronous closure selects the
synchronous overload even in an async caller; an async closure selects the async
overload. Do not add `Async` suffixes or unsafe isolation attributes. Calling a
synchronous `nonisolated` actor method needs no actor hop. A synchronous
MainActor method can also be called from a synchronous scope on MainActor.
Other actor-isolated access still requires an appropriate await. Admission does
not serialize native calls or grant actor isolation the caller does not have.

The quiet-entry result distinguishes ignored work from a delivered optional value.
Use a shared explicit result, conceptually `SystemEntry<Result>` with `.ignored`
and `.performed(Result)`, for these scopes and the quiet state operation below.
The synchronous body is nonescaping and runs on its caller's isolation. The
async body preserves explicit isolation and has Sendable inputs/results. An
entry reserves its activity count atomically with the admission check, releases
protection, invokes the body, then releases borrowed native references and
captures before completing the activity. Core joins the whole body, including
application delegate delivery and capture release.

A Diorama-owned callback must keep both its state update and delegate delivery
in this scope. A check of `isClosed` followed by untracked delivery is insufficient. Async
scopes are awaited; they do not silently spawn detached or unowned tasks.
Synchronous native callbacks use `performIfOpen`. If an adapter needs to bridge one
to asynchronous work, that bridge must use an explicitly owned task whose
shutdown is joined; an ad hoc `Task` is not accepted as evidence of drainage.
Existing scheduled replay work remains owned and joined by the scheduler.

Add a matching synchronous `SystemRuntime.withActiveStateIfOpen` for callbacks
and intentional no-ops. It has the same protected inout state and operation token
as `withActiveState`, but returns `.ignored` on closed admission without adding
a misuse diagnostic. Ordinary application calls keep `withActiveState`.
This is necessary even inside an admitted resource scope: finish can close state
admission between the resource entry and its attempted semantic update. The
Diorama-owned callback must inspect the quiet state result and deliver only when
that update was admitted. An `isClosed` precheck would leave this race unresolved.
A resource scope does not implicitly authorize new state observations after the horizon.

Core rejects all resource entry inside either protected state operation before
invoking foreign code or attempting a nested key-path state lookup. Retain the
safe rejection fact synchronously under DD05; reporting invokes no consumer
code and needs no deferred delivery. Callers first commit
semantic changes and then perform the native action outside protection. An
actor hop never carries an inout state reference or `SystemOperation` token.

Swift rejects awaiting a resource operation in a synchronous state closure and
rejects an escaping task that captures its inout state directly. It does not
prohibit copying a Sendable field or a handle and capturing that copy in a task.
Starting tasks inside state protection remains an authoring-contract violation;
the synchronous closure signature is not a general compile-time task ban.
Likewise, synchronous `perform` inside a state operation is rejected by Core's
runtime guard, not by Swift's type system.

Both `Task {}` and `Task.detached {}` are unstructured. Core tracks a resource
scope until its body returns or throws; structured child tasks finish within
that scope. An unstructured task must not use the raw resource after the scope
ends. Join all such work before leaving the scope, including error paths, or
make it explicit resource-owned work joined by finalization. Capturing a managed
handle and entering a later scope preserves access checks, but does not make
the surrounding task execution-owned or something finish automatically joins.

Actor reentrancy across an await does not make a whole native operation atomic;
any domain phase that must survive suspension still needs an explicit state.
Prefer short synchronous resource scopes on the native actor for commands such
as starting observation. An async scope admitted before stop can reach its actor
or resume from suspension after `didBeginFinalization`. Its bridge must observe
its stopping phase and avoid restarting native work. The scope guarantees lifetime
and joining, not serialization across awaits or cancellation of arbitrary code.
Test this actor-hop race explicitly; an activity counter alone does not solve it.

During construction, `perform` permits setup work; scenario observations,
consumer callback delivery, and replay scheduling remain closed. Core exposes
no running execution or dependency lookup yet. Definitions must not publish
handles from a factory or launch unowned configuration tasks; arbitrary captured
reference escape is an author obligation, not something a TaskLocal can prevent.
Private native acknowledgements needed for configuration and shutdown must
remain serviceable in all lifecycle phases. They are control traffic, not scenario
observations, and must not be routed
through the consumer-delivery gate.

Quiet entry is available only after startup publication, so startup callbacks
cannot deliver consumer work. It also lets an escaped facade implement a specified
no-op, such as Location stop after finish, without a racy `isClosed` check.

After the horizon, no scope grants permission to create a new observation or
extend the horizon. Already admitted work may complete according to its native
contract and acknowledge existing claims; it does not regain recording admission
by holding a resource reference. Final freeze reflects the observed prefix and
existing open-record rules.

After finish, resource handles retain only their closed gate, safe identity,
and reporter. Raw objects and cleanup closure captures belong to the ledger
and are released outside locks after drainage. Systems that require frozen
properties retain explicit stable values, as amended below. A stopped native
callback is silently ignored;
an explicit application operation follows its system's closed-handle policy.

The compiler cannot prevent a resource scope from copying an arbitrary native
reference elsewhere. Such escape is prohibited except for the deliberate native
application dependency returned by a dependency factory. URLSession keeps
DD12/DD20's tested invalidated-session contract for that exception. Its private
bridge must still detach routing and release execution state. Returning a native
handle does not establish its lifecycle safety by itself.

### Consumer-owned live work

A resource scope covers the native call or Diorama-owned callback being admitted,
not the entire lifetime of a consumer-owned live operation. In particular, an
HTTP record adapter must not hold `perform` around the eventual completion
of an arbitrary live request. At the horizon, its managed bridge removes scenario
observation and routing; an already admitted live operation may continue through
the minimal independent forwarding tail required by DD12. That tail owns no
managed resource handle, mutable runtime, recording lease, or execution callback.

The record registration's `willEndFinalization` awaits observation detachment and release
of its execution graph, not the live request or eventual graceful session invalidation.
Its quiet entry gates the scenario observation, while live consumer delivery
belongs to the independent forwarding path and continues when observation closes.
Replay's bridge instead joins all replay-owned delivery and native shutdown.
The same resource API supports these different ownership obligations through
mode-specific bridges. Native tests must prove that distinction; this decision
does not replace DD10/DD12 with cancellation or drainage of consumer-owned work.

An admitted body also must not await the same execution's `finish`, including
through another task that waits on that body. That creates a self-join. Core can
own and join its work, but cannot prove arbitrary consumer wait graphs; the
execution owner must finish after the callback returns. Synchronous blocking of
an actor needed by shutdown has the same limitation. These are explicit limits,
not guarantees that actor isolation or a resource gate can establish.

## Startup, rollback, and cancellation

The coordinator follows this order:

1. Resolve and validate all systems and their stable tracks. No native resource
   exists before all required validation succeeds.
2. Create an attachment's ledger, then await its selected state factory. Resource
   registration immediately joins that ledger, including during partial setup.
3. Install the state into Core, then await its dependency factory. Repeat in
   declaration order. Do not activate attachments concurrently.
4. Atomically commit publication after the last factory succeeds: establish the
   shared time origin, open runtime admission, and transfer passthrough ownership.
   Return the complete execution; no dependency becomes public earlier.

Cancellation is a startup outcome, not an alternate cleanup mechanism. Core
checks it before invoking factories, after their awaits, and at publication.
Registration itself must accept ownership even if cancellation has arrived;
Core does not begin rollback while the factory is still running. If cancellation
wins the publication transition, no execution escapes and Core awaits rollback.
If publication wins, explicit `start` returns the owned execution even if the
caller is canceled immediately afterward; it must not throw after transferring
ownership. The scoped `execute` path already owns that execution and finalizes it
on cancellation, including cancellation before its body begins.

Preserve DD18's sequential consumer execution contract across the new awaits.
`Diorama` keeps its per-instance admission closed through startup, rollback,
finalization, and publication. Its report stays nil until the attempt completes;
a successful startup followed by a body error retains the final report before
rethrowing that original error. Startup failure leaves the stored report nil
and carries its completed failure evidence in the thrown startup outcome.

A canceled or throwing factory must first unwind before rollback inspects its
state and resources. Core must not clean an object concurrently with unfinished
configuration. Native setup must respond to cancellation or its own completion;
Core cannot forcibly interrupt a suspended foreign operation. Test a setup that
ignores cancellation until a controlled gate opens, so this limit stays explicit.

Rollback includes the failing attachment's partially populated ledger, then
completed attachments in reverse order. It uses the same finalization engine
as finish, without recording merge or publication. The ledger is retained until
cleanup completes even though no `RecordState` was returned. Rollback failures
remain attached to the original startup failure and do not hide it.

Once rollback or finish begins, a Core-owned, retained task performs cleanup.
Cancellation of a waiting caller does not cancel it; no detached task or async
cleanup in `deinit` is required. All concurrent finish callers await the same
result. The explicit execution API still requires an awaited `finish`; discarding
an uncanceled startup task or an execution is not automatic asynchronous teardown.

## Finalization order

The ordering matters as much as the signatures:

```text
close admission and stamp horizon
    -> stop scheduler admission / cancel pending registrations
    -> didBeginFinalization on every managed native resource
    -> drain admitted resource scopes, state operations, direct replay reads, and scheduler deliveries
    -> await willEndFinalization in reverse order
    -> freeze records and any system-specific stable property values
    -> detach resources and state; build candidate; freeze report
```

Core first closes the common gate and requests scheduler stop **without awaiting
its drain**. It then invokes every resource's `didBeginFinalization` in reverse
attachment and registration order. Every request precedes any wait for quiescence.
A callback blocked on a native decision must receive its shutdown signal before
Core joins that callback.

Next, join admitted resource scopes, scheduler deliveries, and state operations
while resources remain retained. Only then await `willEndFinalization` actions in reverse
order. This prevents destruction underneath an admitted scope. Every wait needed
to release an admitted scope must have been signaled by `didBeginFinalization`;
it cannot depend on the later `willEndFinalization` call starting shutdown. The acceptance
test with a callback awaiting a shutdown signal makes this distinction observable.

For a native API whose shutdown can only begin asynchronously, the bridge needs
an owned shutdown operation that `didBeginFinalization` signals or starts.
`willEndFinalization` joins that operation. Such a task must be retained and joined, never
fire-and-forget; its actual progress and cancellation behavior require adapter
evidence. The first implementation must prove this pattern if a target native
API requires it, rather than weakening the stop-before-drain rule.

The final hook completes the mode's native acknowledgement and actor-specific
release after admitted users drain. Core drops its final resource references only after
`willEndFinalization` returns, and freezes records only after all these boundaries complete.

This changes the current scheduler-first awaited join and post-freeze cleanup
ordering. It preserves the horizon and deterministic report order. Retain cleanup
facts and recording impact immediately so internal candidate-health decisions
see them before freeze. Public reports remain nil through drainage and cleanup;
finalization exposes the completed immutable report. Facts recorded afterward
enter the separate post-finish log. There is no diagnostic delivery phase,
consumer callback, or notification join. A failure concerning candidate integrity
invalidates publication; an ancillary cleanup failure is reported without
automatically treating every valid recording as unhealthy.

Both hooks are nonthrowing, and each returning `willEndFinalization` produces a
disposition, so one reported cleanup failure does not skip later resources. A callback that
never returns can still prevent completion. No success or quiescence result may
be fabricated to escape that wait. No state lock is held during any hook, await,
application delegate delivery, native-resource/callback-capture destruction,
or native callback. Safe diagnostic fact retention itself invokes no foreign code.

## Passthrough construction and handoff

Successful passthrough remains a plain native dependency. It has no managed mode
state, resource wrapper, post-finish check, interception, or execution-owned
shutdown. Existing injected consumer-owned sources can still be returned directly.

A newly constructed dependency may nevertheless need cleanup if startup fails
before anyone receives it. A separate borrowed `PassthroughConstructionContext`
provides the matching `registerDependency(_:willAbandon:)` form: synchronous,
nonthrowing registration of an author-created value with an abandonment action
that Core awaits before abandonment completes. It returns the same ordinary value.
The same author obligation applies: register immediately, before fallible or
suspending configuration. This context
exposes no track access or managed runtime. The factory returns the ordinary
dependency, with ordinary copying semantics.

On a throwing factory, later attachment failure, or cancellation before
publication, Core awaits abandonment in reverse order. At successful publication,
Core discards those abandonment actions without invoking them and transfers the
native ownership obligation to the consumer. Finish cannot reach them afterward.
This is temporary startup ownership, not a `PassthroughState` or managed live mode.
The public facade must actually retain the native resource it takes ownership of;
Core cannot infer or repair an arbitrary consumer object graph.

## What prevents mistakes

| Invariant | Enforcement |
| --- | --- |
| Actor-isolated native access | Swift isolation checking, Sendable bridge references, and isolation-preserving hook types. |
| No suspension with mutable Core state | Existing synchronous inout operation boundary and compiler rejection probes. |
| No throw/await in `didBeginFinalization`; no throw from `willEndFinalization` | Function types; ordinary compiler rejection is required. |
| No ownership rejection or suspension during registration | Synchronous, nonthrowing registration, including from a canceled task. |
| Registration before fallible configuration | Author obligation; construct and register together before subsequent fallible or suspending work. |
| Partial factory failure and later rollback | Ledger exists before state construction; one shared Core cleanup engine. |
| No late consumer callbacks and no cleanup before admitted work drains | Atomic entry gates, whole-scope accounting, ordered stop requests, awaited joins. |
| No manual finish races or abandoned cleanup after caller cancellation | One retained Core-owned completion task and immutable result. |
| Raw-reference escape, truthful finalization, safe reentry, no blocking request bodies or recursive finish waits | Explicit author obligations plus controlled adapter tests; Swift cannot prove these properties for arbitrary foreign APIs. |

The resource helper owns lifecycle coordination, not domain phases. It has no
location, HTTP, subscription, interaction, matching, or persistence machinery.
No third-party dependency, deployment-floor change, unsafe isolation annotation,
or additional supported platform is proposed.

## Reconciliation and migration

This decision extends DD20's single system-definition boundary. It replaces
synchronous factory requirements with async requirements that still admit sync
witnesses, makes explicit startup async, and replaces direct record/replay state
cleanup with typed resource registrations. Ordinary `RecordState: Sendable` and
`ReplayState: Sendable` remain; no resource protocol or base class is required
for either state. Existing synchronous Random/Date state and operations keep
their shape. Only lifecycle/startup callers and fixtures that implement cleanup
need that lifecycle migration. Every passthrough factory also gains the borrowed
construction-context parameter, even when its synchronous body ignores the
context. This is not a promise of zero source changes for simple definitions.

DD20's passthrough factory gains a construction context for temporary rollback
ownership. This refines its partial-construction obligation without changing
ordinary copying semantics or the consumer's live lifetime after publication.
The explicit registration-before-fallible-work obligation applies equally to
record/replay resource construction and newly constructed passthrough resources.

DD10's awaited finish, reverse rollback, immutable result, and consumer-owned
live-operation horizon remain. This decision specifies the stop/drain/end/freeze
order in place of a scheduler-first awaited join followed by post-freeze native
cleanup, and requires one cancellation-independent cleanup owner. DD14's
scheduler must expose stop-request and drain phases usable in that ordering;
its logical timing and deterministic delivery semantics are unchanged.

DD12's native URLSession invalidation exception and independently continuing
consumer-owned forwarding remain. DD16's MainActor facade and quiescent
record/replay delivery remain. Neither native contract is established by the
signature probes or by synthetic lifecycle tests alone. DD18's startup and
repository wrappers propagate async activation while preserving typed failure,
rollback evidence, and candidate/publication behavior. Persistence schemas,
stable values, dependency policy, and deployment floors do not change.

## Alternatives considered

Owner-requested consideration on 2026-10-11: before Fa08 implementation, compare
the selected pre-factory ledger with
[factory-owned partial construction](../managed-native-lifecycle-options.md#selected-amendment-factory-owned-partial-construction).
The alternative transfers ownership only after a successful factory return;
authors clean partial construction, and Core retains rollback and finalization
of successfully returned resources. It deliberately relaxes Core's guarantee for
a factory that never returns, while retaining async activation and managed access
after transfer. No alternative is selected by this note. The registration,
rollback, passthrough, and acceptance requirements in this decision remain the
approved contract pending an explicit amendment.

The [ownership comparison](../managed-native-lifecycle-options.md) records the
owner's selection. Separated state could remove public handles but adds a state
protocol, two views, and staged ownership rules. The owner prefers the more
direct state-plus-handles model with runtime key-path access. A protocol or base
class alone cannot intercept arbitrary native methods or close partial startup.

- **Only add async factories and cleanup hooks.** This permits actor hops but
  still loses cleanup ownership when a state factory throws before returning.
  It also leaves callback admission and stop-before-join ordering to each author.
- **Have Core invoke a construction closure.** This enforces registration before
  returning the new resource, but adds a closure and potentially an actor hop.
  The owner prefers direct synchronous registration and accepts responsibility
  for avoiding fallible work between acquisition and registration.
- **Make every runtime an actor.** Synchronous Random/Date APIs would need a second
  access strategy, and actor reentrancy would still require lifecycle rules.
- **Give every definition several shutdown hooks and a resource bag.** This
  increases independent obligations; the resource declaration keeps
  each resource and its required actions together.
- **Keep direct state cleanup alongside resource cleanup.** Two ownership paths
  make double shutdown and incomplete partial-construction rollback easier.
- **Build resources before Diorama startup.** That cannot establish validation
  before activation or execution-owned rollback.

## Feasibility and acceptance gates

Exploratory signature probes used small stand-in types, not production Core.
Their source is omitted from the review unit at the owner's request; the
recorded findings remain below. They check synchronous and MainActor factory
witnesses, borrowed contexts across async calls, synchronous nonthrowing resource
registration, MainActor and instance-actor lifecycle actions, both handle and
key-path access overloads, synchronous facade construction, and passthrough
registration/handoff. Nine negative probes exercise throwing/suspending begin,
throwing end, context escape, wrong-actor direct/key-path access, suspension in
an instance-actor begin action, async state access, and escaping inout capture.
Positive counterexamples confirm that copied handles and raw Sendable references
can escape; neither a synchronous state signature nor a resource handle makes
all misuse a compile-time error.

The separate exploratory overload selection probe executes on macOS/Linux
and compiles for iOS. It checks synchronous callers,
synchronous closures inside async callers, async closures, and synchronous
MainActor callers through both direct handles and key-path conveniences. It is
an isolated stand-in with no admission, ownership, or cleanup implementation.
These probes cannot close R5 or prove runtime rejection of nested resource entry.

Checked on 2026-10-11 and reverified after the Fa09-based restack on 2026-10-13:

| Target | Toolchain | Result |
| --- | --- | --- |
| macOS arm64, macOS 15 deployment floor | Xcode 27.0 / Apple Swift 6.4 | Signatures and all nine rejections pass; overload execution passes. |
| iOS Simulator arm64, iOS 18 deployment floor | Xcode 27.0 / Apple Swift 6.4 | Positive signatures and all nine expected rejections pass. |
| Linux x86_64 | Pinned Swift 6.4 release image | Signatures and all nine rejections pass; overload execution passes. |

All signature checks emit SIL; overload selection also executes on macOS/Linux.
They do not run an iOS app or native lifecycle. All use
Swift 6, complete strict concurrency, warnings as errors, explicit nonisolated
default isolation, `NonisolatedNonsendingByDefault`, and
`InferIsolatedConformances`. Repository formatting and strict lint also pass.
Production code is unchanged by this design unit. The restack's shared production
checks are recorded in [Fa03's evidence](../evidence/003-Fa03-whole-track-admission.md).
The Fa08 probes reproduce their results unchanged on all three platforms; they
do not establish the integrated lifecycle behavior still required below.

[Fa08](../plans/003-clean-slate-implementation.md#003-fa08--managed-resource-handles-and-actor-owned-lifecycle)
implements this public boundary as one review unit, with atomic commits for
startup migration, managed lifecycle/access, and integrated public evidence as
useful. The owning plan records implementation status. Actual native
Location/URLSession evidence remains in G08/I01; synthetic actor conformance is
not native capability evidence.

The integrated acceptance matrix must cover:

- validation failure before any native construction; record and replay;
- successful actor construction and dependency publication from MainActor and
  another task, with no author lock or unsafe annotation;
- same-name synchronous and asynchronous handle/key-path overloads, synchronous
  closure selection inside async callers, nonisolated actor methods, correct
  MainActor calls, and compiler rejection of wrong isolation or inout escape;
- resource entry rejected inside state protection before native code runs,
  with synchronous fact retention, plus finalization between key-path lookup and
  resource entry; an extracted handle must not bypass the closed gate;
- failure during configuration, dependency construction, and a later attachment;
- cancellation before and during registration, configuration suspension, factory
  return, and publication race, including registration from an already canceled
  task and configuration that temporarily ignores cancellation;
- a held callback that cannot drain until stop is requested, a held native cleanup
  acknowledgement, concurrent/canceled finish callers, and callbacks after close;
- finish between resource admission and state entry, with quiet callback rejection,
  no new observation, and no spurious application-misuse diagnostic;
- synchronous native callback reentry during stop, callback-capture destruction,
  freeze timing, and actor reentrancy during async operations;
- retained diagnostic facts from rejected and throwing operations, cleanup health
  visible to internal candidate decisions, reports remaining nil through held
  cleanup, and immutable completed reports with separate post-finish facts;
- consumer overlap rejection through async startup and rollback, sequential reuse,
  and retained final reports after original body failure or cancellation;
- an admitted async native operation reaching its actor or resuming after stop,
  without restarting observation or native work;
- reverse resource and attachment cleanup, a reported cleanup failure followed by
  remaining cleanup, and system-specific frozen properties after resources are released;
- weak-reference release with retained managed facades and resource handles;
- passthrough abandonment before publication and native ownership after it;
- record-mode detachment while an unfinished consumer-owned live operation
  continues independently, contrasted with complete replay-owned drainage;
- normal source/record ordering, scheduler ordering, claims, persistence, and all
  existing Random/Date/consumer conformance on macOS, iOS Simulator, and Linux.

R5 stays open until the approved production boundary passes that matrix. This
decision defines the ownership model and its limits; it does not claim those
runtime guarantees are implemented.

## Swift references

[SE-0431](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0431-isolated-any-functions.md)
provides function values that preserve dynamic actor isolation. It supports the
synchronous actor-isolated hooks whose invocation Core can await.
[SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)
explains the enabled async isolation defaults; this design uses explicit isolation
at stored hook boundaries rather than assuming a particular startup caller.
[SE-0306](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md)
describes actor reentrancy, and
[SE-0304](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md)
describes cooperative cancellation and task ownership. These are language
foundations, not evidence that Diorama's lifecycle implementation is correct.
[SE-0296](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0296-async-await.md#overloading-and-overload-resolution)
permits sync/async overloading; the probes verify the selected closure overloads
with the repository's toolchain and isolation settings.
[SE-0313](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0313-actor-isolation-control.md)
provides nonisolated actor declarations and isolated actor parameters.

## Recording lifetime alignment — 2026-10-11

The owner-approved [DD20 lifetime amendment](20-system-definitions-and-pure-passthrough.md#recording-lifetime-and-replay-continuation-amendment--2026-10-11)
removes `SystemRuntime.snapshot()` and `SystemSnapshot`. References to frozen
property values here require small system-specific retained state, not a generic
runtime projection API. Date and Random recording dependencies retain their live
sources after closure, with diagnostics and no recording; sequential replay uses
track continuation policies. This does not change Location/URLSession shutdown,
resource-ledger ownership, or the lifecycle gates defined by this decision.

## Final-report diagnostic alignment — 2026-10-13

The owner requests restacking Fa08 on the Fa09-based Fa02 revision. This applies
[DD05's approved final-report-only contract](05-consumption-and-verification.md#final-report-only-diagnostics--owner-approved-2026-10-12)
and DD20's diagnostic amendment to this design. They supersede its earlier
references to deferred diagnostic delivery, sink reentry, and publicly observable
cleanup facts before freeze. Reporting retains facts and health synchronously;
only completed reports and the separate post-finish log are public. Future
inspection is a separately reviewed capability and must not introduce a sink.

Resource admission, actor hops, native callback scopes, capture destruction,
stop-before-drain ordering, and awaited cleanup still require ownership and
joins. Those obligations do not come from diagnostic delivery. The selected
resource signatures and the pending comparison of factory-owned partial
construction are unchanged by this reconciliation. Fa09A's consumer admission
and retained-report guarantees also continue across async startup and cleanup.

## Factory-owned construction — owner-approved 2026-10-13

The owner selects factory-owned partial construction and authorizes Fa08
implementation on top of the design branch. This amendment supersedes the
original immediate-registration, pre-factory ledger, and borrowed passthrough
construction-context requirements, including their examples and acceptance
clauses. The original design remains above as the history of the decision.

A factory owns everything it creates but does not successfully return. Ordinary
Swift destruction is sufficient when that is the resource's cleanup contract.
When construction starts activity requiring explicit stop or awaited cleanup,
the factory handles that activity before throwing, including cancellation.
This is the same responsibility as any throwing Swift factory; Core cannot
recover resources it never receives. No Core partial-construction ledger or
mandatory registration-before-fallible-work ordering remains.

Record and replay state factories return a `SystemState<State>` containing the
ordinary state and an explicit ordered collection of typed `SystemResource`
handles. A resource carries its native value and paired nonthrowing
`didBeginFinalization` / asynchronous `willEndFinalization` actions. The state
result declares its owned resources through `owning(_:)`; heterogeneous erasure
is private to this collection. Simple state returns `SystemState(value)` and
needs no resource declaration. Resources are constructed during activation,
after validation. Returning the state successfully transfers its declared
resources to Core synchronously, before another cancellation check or await.
There is no separate throwing registration step. Resources belong to one state
result and execution; reusing a resource across activations is an author error.

Core retains successful state results while dependency construction runs.
Dependency factories return their ordinary facade and own their own failed
partial construction. Any additional resource needing execution-owned shutdown
must be part of the state result; a dependency factory must not publish or retain
unmanaged execution work. If dependency construction fails, Core closes and
awaits cleanup of the returned state's resources before earlier attachments.
Cancellation after successful return likewise cannot discard a cleanup obligation.

A passthrough factory returns `PassthroughDependency<Dependency>`, containing its
ordinary dependency and an optional asynchronous, nonthrowing abandonment action.
The default action is empty, including for injected consumer-owned dependencies.
Core owns only that returned abandonment obligation until startup publication.
On later failure or cancellation it awaits the action; on publication it drops
the action without invoking it and transfers ordinary native lifetime to the
consumer. No passthrough construction context, managed state, or post-finish gate
is introduced.

The stop-before-drain ordering, admission gates, quiet callback entry, final
reports, and cancellation-independent Core completion task remain unchanged.
State detaches after record freeze; owned native resources and cleanup captures
release outside locks after awaited shutdown. Cleanup outcomes retain safe labels
and never skip later resources. Core does not require a new reporting protocol
for factories' local cleanup: existing safe diagnostics and typed startup failure
evidence remain the boundary; arbitrary native errors are never rendered.

Replace registration and Core partial-rollback probes with public-boundary tests
for factory-owned ordinary and explicit cleanup, including canceled construction,
and Core rollback of successfully returned state/dependencies. Prove cancellation
at the successful-return boundary, state success followed by dependency failure,
passthrough success followed by later failure, reverse shutdown, and retained
facades releasing native captures. The remaining DD21 acceptance matrix applies.
The earlier stand-in signature probes are historical evidence for the original
API; production compiler probes and integrated tests establish this amended API.

## State-owned lifecycle — owner-approved 2026-10-15

The owner requests implementation of the revised Fa08 design and consolidation
into the existing implementation and PR. This amendment accepts the
[state-owned lifecycle contract](../plans/003-Fa08-lifecycle-redesign.md) and
supersedes the resource-handle and temporary passthrough-ownership contracts
above. The earlier decision and construction amendment remain historical records.

Every mode has an ordinary Sendable State factory and a Dependency factory.
`PassthroughState` defaults to `Void`, with an empty default factory. Core
validates every attachment before sequential activation in attachment order.
Factories own partial construction they fail to return. Core adopts returned
State before the next cancellation check or suspension, waits for Dependency
construction to settle, and then owns any successfully returned Dependency.
Publication follows all successful activations. No return wrappers, resource
lists, resource registration, or independently callable resource handles remain.

`SystemDefinition` supplies `requestStopRecord` / `cleanUpRecord` and equivalent
Replay/Passthrough hooks. Requirements are async and nonthrowing; synchronous
and actor-isolated witnesses are supported. Each hook receives a borrowing,
noncopyable `SystemLifecycleContext<State>` and `Dependency?`. The outer optional
means State-only versus a returned Dependency, preserving `.some(nil)` when
Dependency is optional. Defaults request nothing and return `.completed`.
Stop signals activity needed to unblock drainage; it must not wait for that
drainage. Cleanup joins all owned activity. `.failed(label)` describes ancillary
failure after quiescence and never prevents another attachment's cleanup.

`SystemExecution.state.withLock` replaces `withActiveState`. Its synchronous
body receives protected `inout State` and `SystemOperation`. The state view's
`withTrackedValue` selects a member by typed key path under protection, after
admission and counting, then runs the body outside protection. Synchronous and
async overloads preserve actor isolation and count the entire scope, including
throws and suspension. Quiet `withLockIfOpen` / `withTrackedValueIfOpen` return
`SystemStateAccessResult` (`ignored` or `performed`) and admit only after
publication and before closure. Nested entry under state protection rejects
before key-path evaluation or native invocation. No whole-state snapshot API
or lock spanning an await is introduced.

Lifecycle contexts expose only `state.withLock`, with no operation token,
recording, or scheduling. The view shares the runtime's State storage but has
separate permission for one hook invocation. It expires when the hook returns;
Core joins any admitted synchronous access before the next lifecycle phase.
Retaining the view cannot reopen consumer admission or reuse lifecycle
permission. Authors select native references under protection and invoke them
outside it on their actors. Borrowing prevents context escape, not copied native
reference escape. Unstructured tasks, replacement of live native members, and
external reference synchronization remain explicit author responsibilities.

Rollback and normal finish use the same stop/drain/cleanup engine. Close common
admission first; normal finish stamps the horizon and requests scheduler stop.
Invoke every returned State's stop hook in reverse attachment order before
joining any operations, scheduler deliveries, or direct replay reads. Then
await cleanup in reverse order, freeze accepted records while State remains
available, detach State, release Core's Dependency references outside locks,
and build the candidate and final report. Rollback closes tracks without merge.
A failed Dependency factory's State participates in this same rollback, with
its own cleanup outcome. One cancellation-independent Core task owns completion.

Reconciliation:

- DD20: passthrough now has State/runtime and receives hooks after publication
  too. It still creates no track leases, interception, or record/replay access.
  Ordinary dependency operations keep native behavior. System hooks determine
  shutdown and escaped-dependency usability; no-op hooks preserve an injected
  consumer-owned dependency. Hooks tolerate consumer-initiated shutdown.
- DD10: all returned States and Dependencies remain owned through cleanup.
  Stop-before-drain and cleanup-before-freeze replace earlier sequencing where
  inconsistent. Retained consumer references need not deallocate at finish.
- DD19: lifecycle mutation may prepare the final state seen by accepted record
  freeze; cleanup must preserve those records. A late accumulator rejected at
  registration still freezes once for disposal under DD19's existing contract.
  It is not an accepted recording and cannot contribute to the candidate.
- DD05/Fa09: report visibility remains final-only, including release-time facts,
  recording health, and separate post-finish diagnostics. No diagnostic callback
  or implicit test-outcome policy is introduced.

Production public compiler probes and runtime tests replace evidence for the
superseded handle API. Native Location and URLSession conformance remains at
G08/I01; this amendment introduces neither adapter nor dependency.

## Typed mode definitions — owner-approved 2026-10-16

The owner approves implementation of `SystemModeDefinition<State, Dependency>`
after discussing the fresh infrastructure review's F2 authoring concern. This
amendment replaces the twelve mode-specific factory and lifecycle protocol
requirements with three required `SystemDefinition` properties: `record`,
`replay`, and `passthrough`. Their declaration types share `Dependency` and bind
their respective `RecordState`, `ReplayState`, and `PassthroughState`. The
existing system identity, typed tracks, and validation boundary remain.

Each immutable, Sendable mode definition groups four typed callbacks:

- `makeState`: borrowing `SystemStateContext`, async throwing, returning State;
- `makeDependency`: `SystemExecution<State>`, async throwing, returning Dependency;
- `requestStop`: borrowing `SystemLifecycleContext<State>` and `Dependency?`,
  async nonthrowing;
- `cleanUp`: the same lifecycle inputs, async nonthrowing, returning
  `SystemCleanupResult`.

Synchronous and actor-isolated callbacks remain supported, supplied as inline
closures or references to named methods. Stop defaults to no work and cleanup
defaults to `.completed` through initializer arguments. Supplied callbacks are
checked against these function types; a throwing lifecycle function cannot
silently leave a default protocol witness selected. Omitted callbacks still
mean no owned shutdown work, and runtime tests must verify native cleanup.

The general initializer requires both factories. Two constrained initializers
for `State == Void` supply an empty State factory and accept either a dependency
factory receiving `SystemExecution<Void>` or a zero-argument dependency factory.
Both retain optional lifecycle callbacks: a Void State does not imply that its
Dependency owns no activity. `makeState` and `makeDependency` are the selected
factory names. No implicit mode declaration or State-as-Dependency conversion
is introduced. Empty tracks and no additional validation retain their defaults.

Declarations describe reusable configuration. Reading one must not construct
live execution resources; construction belongs in its factories. After every
attachment validates, Core obtains only the selected mode declaration once for
that activation and uses that same declaration's factories and shutdown hooks.
Every execution still creates fresh State. The declaration's construction-only
captures need not remain owned by its activated lifecycle.

All state-owned lifecycle semantics remain: factories unwind failed partial
construction; Core adopts each successful return before cancellation can
abandon it; optional nil dependencies preserve the outer ownership optional;
stop precedes drainage; cleanup precedes freeze and release; and one owned task
completes finalization despite canceled waiters. Passthrough retains its
system-defined native lifetime and no track access. This changes authoring,
not scheduling, persistence, diagnostics, or application-consumer execution.

The old mode-specific methods are removed from the public protocol without
compatibility forwarding. Migrate first-party definitions, consumer proofs,
compiler probes, and the current authoring guide together. Earlier decision and
Fa08 evidence remain historical. The current public probes must reject actual
throwing callback signatures, missing mode declarations, and incompatible State
or Dependency types, with ordinary compiler diagnostics rather than crashes.
