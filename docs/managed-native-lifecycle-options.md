# Managed native lifecycle: alternatives and selection

The [October 13 amendment](#selected-amendment-factory-owned-partial-construction)
supersedes the original immediate-registration selection recorded below.

- Status: Supporting rationale for accepted Decision 21.
- Recorded: 2026-10-11
- Decision: [Managed native lifecycle](design-decisions/21-managed-native-lifecycle.md).
- Delivery: [003-Fa08](plans/003-clean-slate-implementation.md#003-fa08--managed-resource-handles-and-actor-owned-lifecycle).

The [state-owned lifecycle redesign](plans/003-Fa08-lifecycle-redesign.md),
approved for implementation on 2026-10-15, supersedes the selected resource-handle
contract below. [DD21's amendment](design-decisions/21-managed-native-lifecycle.md#state-owned-lifecycle--owner-approved-2026-10-15)
is authoritative; this comparison preserves the earlier alternatives and rationale.

## Selected approach

The owner selects **explicit typed resource handles**, retaining ordinary State
and `SystemDefinition` types. Authors construct a native owner and immediately
register it before subsequent fallible or suspending work. Core returns a
`SystemResource<T>` handle and retains the cleanup obligation independently of
whether the state factory returns successfully.

Facades can access a handle directly through `perform`, or use the retained
`runtime.withResource(keyPath:)` convenience. Both names have synchronous and
asynchronous overloads selected by the closure type. The key path selects a
managed handle, never a raw native field. Core extracts the handle under state
protection, leaves that protection, and admits the native operation through the
handle's gate. `performIfOpen` and `withResourceIfOpen` provide matching quiet
callback entry. No `Async` suffix is needed.

This keeps mutable state and resource lifetime as distinct concerns without
requiring system authors to split State into separate Values and Resources views.
Registration keeps each native resource and its cleanup actions together and
lets Core unwind a partially constructed state with several registered resources.
The owner accepts the registration-before-fallible-work obligation in exchange
for author-controlled construction.

## Effect of final-report-only diagnostics

Fa09 removes diagnostic consumer callbacks. Fa08 therefore needs no diagnostic
notification buffer, delivery phase, sink-reentry handling, or notification join.
Rejected resource entry and cleanup retain safe facts and recording impact
synchronously; public reports become available only at finalization, with a
separate post-finish log. Later inspection must be designed without a sink.

Native callbacks, actor-isolated work, capture destruction, and shutdown
acknowledgement still need the selected resource admission and lifetime rules.
Removing diagnostic delivery does not decide who owns partial construction;
the selected amendment below defines the construction ownership boundary. See
[DD21's diagnostic alignment](design-decisions/21-managed-native-lifecycle.md#final-report-diagnostic-alignment--2026-10-13).

## Workable alternatives evaluated

| Approach | Benefit | Tradeoff and disposition |
| --- | --- | --- |
| Explicit `SystemResource<T>` handles — selected | Visible guarded access and a Core ledger that survives failed state construction. | Requires immediate registration; the runtime convenience reduces access boilerplate. |
| Whole state as an actor/resource owner | One owner with automatic finalization. | Needs a second strategy for synchronous Random/Date and still needs ownership before fallible setup. |
| State with separate values and resources | Automatic adoption without individual handles; separate synchronous value and actor-native access. | Adds a state protocol, two views, and inert-owner-before-configuration rules. The owner finds this harder to understand and prefers handles. |
| Resource lifecycle protocol plus handles | Reuses lifecycle declarations across resources. | Optional convenience over the selected design; not necessary for Fa08. Ordinary State needs no new protocol. |
| Declarative resource builder | Core can own creation/configuration ordering and individual rollback. | More authoring machinery and renewed Core involvement in construction; the owner prefers direct registration. |
| Generated facade or macro | Can insert admission around a declared operation surface. | Requires constrained signatures, callback rules, and tooling/dependency review. Defer until a demonstrated need. |
| Typed command/operation dispatcher | Every supported operation has one Core entry boundary. | Extra operation/result types and indirection; a larger change to the direct facade style. |
| Specialized base class | Final entry methods can guard a fixed operation vocabulary. | New subclass methods can bypass those entries. Class-only inheritance does not support instance actors or ordinary value state. |

The separated-state signatures were feasible, including simple-state defaults,
but signature feasibility did not make that model easier to author. It is not a
second supported API or a fallback silently selectable during implementation.
The selected contract and its public signature probes are maintained in DD21;
exploratory separated-state probes are not part of the implementation handoff.

## Selected amendment: factory-owned partial construction

On 2026-10-13, the owner selects this alternative and authorizes implementation.
The [DD21 amendment](design-decisions/21-managed-native-lifecycle.md#factory-owned-construction--owner-approved-2026-10-13)
supersedes the original registration contract described above.

Factories clean what they fail to return. Ordinary Swift ownership handles inert
objects; factories that start activity explicitly stop and await it when needed.
Core takes ownership of resources declared in successful state results, before
another suspension or cancellation check. Core then owns dependency-factory and
later-attachment rollback as well as normal managed finalization.

Passthrough results carry optional abandonment actions until publication transfers
ordinary lifetime to the consumer. No partial-construction ledger, mandatory
immediate registration, or passthrough construction context remains. Typed handles,
async activation, validation before activation, atomic publication, and awaited
managed shutdown remain. Successfully returned resources carry cleanup obligations
through the factory result; Core cannot recover resources a factory never returns.

The owner accepts ordinary throwing-factory cleanup as an author responsibility.
Multi-resource cancellation and successful handoff are implementation acceptance
cases, not unresolved architectural choices. R5 still requires production evidence.

## Approaches that do not independently solve R5

- A State protocol requiring cleanup methods does not intercept arbitrary field
  or method access, establish partial-construction ownership, or define safe lock
  boundaries. A base class also needs callers to use guarded entry methods.
- Raw native fields plus a remembered scoped helper leave ordinary state access
  able to expose the raw object. Keeping the handle in State preserves the
  normal guarded path.
- A property wrapper returning raw Native finishes its getter before the native
  call or await. It cannot count that operation's duration. Returning a managed
  handle or generated facade instead retains the underlying access abstraction.
- Async factories/hooks alone permit actor hops but do not establish admission,
  partial rollback, or shutdown-before-drain ordering.
- Making every state an actor does not preserve synchronous Random/Date APIs.
  Actor reentrancy also does not provide quiescent finalization.
- Noncopyable tokens and borrowed inout access constrain those values' lifetime;
  they do not prevent copying an ordinary Sendable reference out of a scope.
- Resource lists and reflection cannot prove that all native ownership has been
  declared, infer cleanup semantics, or recover a state that never returned.
- Weak references and `deinit` cannot supply the required awaited shutdown and
  startup rollback contract.
- A universal proxy cannot transparently wrap every arbitrary concrete native
  Dependency permitted by DD20. Native adapters still need their own evidence.

## Remaining author obligations

Neither handles nor the alternatives make arbitrary native reference escape
impossible. Swift rejects escaping capture of borrowed inout State, but allows
copying a Sendable field and capturing that copy in a task. Both `Task {}` and
`Task.detached {}` are unstructured. Native work must remain in its resource
scope, enter a fresh scope through a retained handle, or have explicit resource
ownership and awaited shutdown. A retained handle does not by itself make the
surrounding task execution-owned.

The owner must also honor stopping phases across awaits, avoid reentry while
state protection is held, and establish actual native quiescence. These are
explicit adapter contracts tested by the DD21 acceptance matrix, not guarantees
conferred solely by `Sendable`, a protocol, or an activity counter.

Fa08 must prove the selected lifecycle through the production public boundary.
The standalone signature probes establish API feasibility only. R5 remains open
until the integrated proof passes; native Location/URLSession evidence remains
at G08/I01.
