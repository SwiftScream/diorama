# 003-Fa08: State-owned lifecycle redesign

- Status: Approved for implementation by owner on 2026-10-15.
- Recorded: 2026-10-14
- Owning unit: [003-Fa08](003-clean-slate-implementation.md#003-fa08--managed-resource-handles-and-actor-owned-lifecycle).
- Existing contract: [DD20](../design-decisions/20-system-definitions-and-pure-passthrough.md), [DD21](../design-decisions/21-managed-native-lifecycle.md).
- Rationale: [Lifecycle alternatives](../managed-native-lifecycle-options.md).

The owner requests implementation of this revised design and consolidation into
the existing Fa08 implementation and PR on 2026-10-15. The
[DD21 amendment](../design-decisions/21-managed-native-lifecycle.md#state-owned-lifecycle--owner-approved-2026-10-15)
accepts this contract and reconciles DD10, DD19, and DD20. The preparatory
async-startup work remains part of the same review unit.

## Factory and ownership contract

Record, replay, and passthrough each have a State factory followed by a Dependency
factory. All systems validate and prepare before any activation. Activation stays
sequential in scenario attachment order: one system's State/Dependency pair
completes before the next begins. Publication follows successful activation of
all systems.

State factories return ordinary `RecordState`, `ReplayState`, and
`PassthroughState` values. These types require `Sendable`, with no lifecycle
protocol or base class. Remove the public `SystemState<State>` and
`PassthroughDependency<Dependency>` return wrappers. Dependency factories still
return the ordinary `Dependency`; record/replay factories retain access to a
Core-created `SystemExecution<State>`. Passthrough gains the equivalent runtime
access boundary, without recording, interception, or replay track access.

`PassthroughState` defaults to `Void`. A constrained protocol extension supplies
its empty-state factory; synchronous and actor-isolated witnesses compile.

| Milestone interval | Ownership and failure handling |
| --- | --- |
| Before State returns | The State factory owns all partial construction and completes necessary cleanup before throwing. |
| State returned; Dependency not returned | Core owns State. The Dependency factory owns anything it constructs but fails to return. After it settles, Core stops and cleans State if startup aborts. |
| Dependency returned; execution unpublished | Core owns both returned results and their lifecycle obligations. Later failure or cancellation invokes the same stop/cleanup hooks with Dependency present. |
| Execution published | Core retains State and Dependency and invokes lifecycle hooks at shutdown in every mode. Consumer references may coexist. |

Adopt each successful factory result before another cancellation check or
suspension. Never clean State concurrently with an unfinished Dependency factory.
Cancellation cannot abandon an adopted obligation. Core's release does not promise
immediate deallocation: callbacks, tasks, or consumer references may retain objects.

For passthrough, Core now initiates shutdown after publication too. System authors
determine its meaning, including a no-op for an injected consumer-owned dependency.
An escaped native dependency's post-execution usability follows that policy.
Consumer-initiated shutdown must be tolerated by the system's hooks.

## Definition-level lifecycle hooks

Use two nonthrowing hooks per mode: request stop and await cleanup. Each receives
a scoped lifecycle context plus `Dependency?`. The following compiler-verified signatures define
the record hooks; replay and passthrough use the corresponding State types:

```swift
func requestStopRecord(
    using lifecycle: borrowing SystemLifecycleContext<RecordState>,
    dependency: Dependency?
) async

func cleanUpRecord(
    using lifecycle: borrowing SystemLifecycleContext<RecordState>,
    dependency: Dependency?
) async -> SystemCleanupResult
```

Replay and passthrough have equivalent mode-specific hooks. Defaults request
nothing and return `.completed`. No separate public construction-phase enum is
needed: `nil` means no Dependency successfully returned, while `.some(result)`
means Core owns the returned result. If `Dependency` is itself optional, preserve
that outer distinction even when a successful factory returns `nil`.

The same pair handles rollback and normal finish. A returned State must support
cleanup without Dependency. Once Dependency returns, hooks can operate on it,
including initiating native session shutdown. The system coordinates internal
resource ordering and continues necessary cleanup after ancillary failures.

Request-stop may require actor hops, but must signal all work needed to unblock
drainage without waiting for that drainage. An asynchronously initiated shutdown
operation must be owned and joined by cleanup. Cleanup returns only after owned
activity stops; `.failed(label)` reports an ancillary failure, not unfinished work.
Native hook implementation must preserve actor isolation without unsafe annotations.

## State access and naming

`SystemExecution` continues to group reporter, time, clock, scheduling, and
admission information. A dedicated `state` access view groups State operations:

```swift
execution.state.withLock { state, operation in
    // Synchronous protected State mutation and existing operation effects.
}

try await execution.state.withTrackedValue(\.session) { session in
    // The entire operation runs outside the State lock and is tracked.
}
```

`withLock` replaces the public `withActiveState` spelling. Its closure receives
protected `inout State`; it cannot suspend. Authors must avoid native reentry,
blocking waits, arbitrary callbacks, and untracked task creation under the lock.
The lock does not establish isolation for native actors or synchronize external
access to shared reference members.

`withTrackedValue` selects one State member through a typed key path. It does not
supply whole-State snapshots or `inout State`. Admit and count the operation before
extracting its value under protection, then release protection before invoking the
body. Keep the entire scope counted through suspension, actor hops, throws, and
return. Finalization joins it before completing cleanup or releasing State.
Provide synchronous and asynchronous overloads with appropriate actor-isolated
closure signatures. The async body uses `@isolated(any) @Sendable`, with a Sendable result and
key path. A synchronous body keeps call-site actor isolation.

This replaces independently callable `SystemResource` handles and their binding
or resource declaration machinery. State can contain ordinary native references;
lifecycle obligations reside on the definition's hooks. Access is tracked through
the runtime, not discovered through reflection or a resource list.

The selected value is not deeply immutable. Reference members retain shared
identity, and State may change after selection. Admitted async operations must
honor native stopping phases when they reach an actor or resume after stop.
Replacing a live native member must not lose its shutdown obligation; dynamic
resource replacement is not added by this proposal.

Keep quiet callback equivalents for locked State and tracked-value access. They
ignore entry before publication and after closure without late-call diagnostics.
Their names are `withLockIfOpen` and `withTrackedValueIfOpen`; both return
`SystemStateAccessResult` with `.ignored` and `.performed(value)` cases. A tracked native scope does not
authorize new State observations after State admission closes.

### Privileged lifecycle access

Lifecycle contexts share the same State storage and protection but use distinct
permissions:

```swift
lifecycle.state.withLock { state in
    // Protected lifecycle access after ordinary admission closes.
}
```

Lifecycle access provides no `SystemOperation`, recording, or scheduling effects.
Native references needed to request stop are selected under protection and used
outside it. No lock or `inout` borrow spans an await. The context is valid only
for its hook invocation; retained access must not bypass that lifetime. Use a borrowed noncopyable
context and a retainable state view with per-hook expiry and admitted-access
drainage. Neither mechanism prevents copied native reference escape.

Reject consumer tracked-value entry from inside locked State access before native
invocation. Direct arbitrary calls through raw State members remain an author
obligation: Swift cannot prevent copying a Sendable reference or launching a task
with it. Track the closure's duration, not unstructured tasks launched inside it.
Additional owned work must have explicit stop and awaited cleanup in the system.

## Common shutdown sequence

Rollback and normal finish use the same owned lifecycle engine:

1. Close common admission; normal finish also stamps the horizon and requests
   scheduler stop without awaiting its drainage.
2. Invoke request-stop on every returned State in reverse attachment order,
   passing Dependency when successfully returned. All stop requests precede joins.
3. Drain admitted State operations, tracked-value scopes, scheduler deliveries,
   and direct replay reads.
4. Await cleanup hooks in reverse attachment order. Retain State and Dependency
   throughout. One ancillary failure must not skip another attachment.
5. Freeze records while State remains available, then detach State and release
   Core's Dependency references outside locks. Rollback closes without merging.
6. Build the recording candidate and freeze the report after cleanup and release.

Cleanup must preserve State needed by record freeze; it cannot clear that data
prematurely. Core retains one cancellation-independent completion task, concurrent
finish callers share its result, and reports remain unavailable through cleanup.
Existing candidate-health and separate post-finish diagnostic rules continue.

## Approval and implementation evidence

The owner authorizes production implementation on 2026-10-15. Verify the
concrete API against public Core imports: actor-isolated and synchronous
factory/hook witnesses, borrowed contexts across async calls, sync/async overload
selection, quiet entry, nested-entry rejection, and retained-view expiry.

Runtime acceptance covers each successful-return boundary, canceled construction,
State success followed by Dependency failure, later attachment failure, all-mode
shutdown, already-stopped dependencies, stop-before-drain, actor reentrancy,
cleanup failure continuation, cleanup changes reaching record freeze, and the
outer optional when Dependency is itself optional. Keep passthrough without track
access, release State/Dependency outside locks, and preserve final-only reports.
The [owning evidence](../evidence/003-Fa08-managed-resource-lifecycle.md) records
actual verification of the revised implementation; old handle tests do not prove it.
