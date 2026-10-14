# 003-Fa08: State-owned and actor-isolated lifecycle

- Revised implementation: 2026-10-15
- Status: Complete; includes the superseded Fa06 public actor-lifecycle proof.
- Plan: [003-Fa08](../plans/003-clean-slate-implementation.md#003-fa08--managed-resource-handles-and-actor-owned-lifecycle)
- Contract: [DD21's state-owned lifecycle amendment](../design-decisions/21-managed-native-lifecycle.md#state-owned-lifecycle--owner-approved-2026-10-15)
- API: [Approved lifecycle redesign](../plans/003-Fa08-lifecycle-redesign.md)
- Review: [PR #86](https://github.com/SwiftScream/diorama/pull/86)

## Delivered boundary

All three modes construct ordinary Sendable State followed by Dependency. The
State factory owns failed partial construction; Core adopts successful results
before another cancellation check or suspension. Dependency construction settles
before any State cleanup. A failed Dependency factory's returned State joins the
same rollback as earlier attachments and contributes its own cleanup outcome.
Successful optional `nil` dependencies remain distinguishable from no return.

`SystemDefinition` owns mode-specific request-stop and cleanup hooks. Borrowed
lifecycle contexts expose privileged locked State access without operation effects.
Retained views expire at each hook return and cannot reopen ordinary admission.
Synchronous and actor-isolated factory/hook witnesses satisfy async requirements.

`execution.state.withLock` replaces `withActiveState`. `withTrackedValue` counts
admission before selecting a typed member under protection, then invokes its
sync/async body outside the lock. The entire scope stays counted through throws,
actor hops, and suspension. Quiet forms ignore entry before publication and after
closure. Nested entry rejects before lookup or native invocation. Independently
callable resource handles, resource lists, and State/Dependency wrappers are removed.

Rollback and finish share a stop/drain/cleanup engine. Every returned State gets
its reverse-order stop request before joins. Core drains State/tracked operations,
scheduler deliveries, and direct replay reads, then awaits reverse cleanup.
Accepted records freeze after cleanup while State remains available. State and
Dependency release occurs outside locks before candidate and report creation.
One Core-owned task completes shutdown independently of canceled finish callers.
Cleanup failures retain safe labels, continue other cleanup, and do not themselves
invalidate a healthy recording. Release-time recording impact still can.

Passthrough now gets the same State and lifecycle hooks after publication too.
The system determines native shutdown and tolerates consumer-initiated stop.
No-op defaults preserve injected native dependencies. Passthrough has no prepared
track access, recording, interception, or wrapper around ordinary native calls.
Date/Random native semantics, retained recording behavior, replay continuation,
and independently owned recording forwarding remain intact.

## Runtime evidence

The lifecycle suites use public imports and controlled gates, including MainActor
and instance-actor resources constructed during activation.

| Invariant | Evidence |
| --- | --- |
| All-mode State-only versus Dependency-returned ownership, successful optional nil, cancellation at both returns | `StateLifecycleTests` |
| No State cleanup while Dependency construction is suspended; both throwing and returning canceled construction | `StateLifecycleTests`, `ResourceStartupTests` |
| Partial activation's tracked work drains only after an earlier attachment stops it | `StateLifecycleTests` |
| All stop requests precede cleanup; failures continue across keyed attachments and all modes | `StateLifecycleTests` |
| Retained lifecycle access expires between hooks and after finish; cleanup updates reach record freeze | `StateLifecycleTests` |
| Dependency destruction reenters quietly and reports before final freeze in every mode | `StateLifecycleTests` |
| Passthrough runtime without declared-track access; stop tolerates consumer shutdown | `StateLifecycleTests`, `ResourceStartupTests` |
| MainActor sync/async and quiet access; retained state views release native references | `ResourceLifecycleTests` |
| Nested access rejects before native invocation; throwing tracked bodies release admission | `ResourceLifecycleTests`, `StateLifecycleTests` |
| Stop unblocks held callbacks; canceled/concurrent finish callers await held cleanup and share a final report | `ResourceLifecycleTests` |
| Actor reentrancy cannot reopen State; stop callbacks and capture destruction run outside locks | `ResourceLifecycleTests` |
| Factory partial failure, later failure, validation-before-activation, and ordinary Swift release | `ResourceStartupTests`, `AsyncStartupTests` |
| Instance-actor work receives stop and awaited join; consumer overlap spans startup/cleanup | `ResourceActorTests` |
| Scheduler stop precedes drainage; independent recording forwarding outlives observation | `ResourceSchedulingTests` |
| Recording, replay, timing, persistence, Date/Random, retained reports, and sequential reuse | Full package regression suite |

## Compiler and local verification

The canonical macOS `scripts/check` passes 448 tests, strict SwiftFormat/SwiftLint,
warnings-as-errors compilation, debug/release builds, and both example builds and
executions on Xcode 27.0 / Swift 6.4. Fresh `scripts/coverage swiftpm macos`
repeats the production gate in an isolated build and exports current-build LCOV.
The coverage fixture, local documentation links, and full-branch whitespace check
also pass. Deployment floors remain macOS 15 and iOS 18.

`scripts/tests/system-authoring` compiles one public definition and checks seven
ordinary compiler rejections for borrowed context/token/state escape and raw track
mutation. `scripts/tests/resource-lifecycle` compiles the revised public API and
checks eight rejections: throwing stop/cleanup, wrong-actor tracked access, async
locked State/lifecycle bodies, borrowed lifecycle context return/capture, and
lifecycle operation effects. Crashes or unexpected acceptance fail the gate.
Positive compilation covers synchronous and MainActor witnesses, borrowed async
hooks, instance actors, default Void passthrough state, sync closures in async
callers, async actor hops, and quiet access.

Both compiler suites run with macOS/Linux SwiftPM tests. The lifecycle suite also
runs against the iOS Simulator products in the canonical coverage command. PR #86's
required macOS, iOS, Linux, Quality, and Codecov checks provide the hosted evidence
for the submitted revision. The iOS runtime suite excludes the existing host-only
subprocess precondition test; current-runtime Simulator evidence does not claim
execution on an iOS 18 installation.

Reproduce local host verification with `scripts/check` and
`scripts/coverage swiftpm macos`. Platform commands and the pinned Linux image are
specified in the [quality policy](../quality-gates-and-ci.md).

## History and limits

The owner combines Fa06/Fa08 into one review unit on 2026-10-14 and omits the
obsolete standalone Fa06 spike. The earlier resource-handle implementation passes
440 macOS/Linux tests and 439 iOS tests after the Fa02 restack. Those results
establish the superseded contract, not this revision. On 2026-10-15 the owner
requests the revised implementation, squashing into the existing implementation,
and updating PR #86. The history retains design, preparatory async activation,
state lifecycle with proving tests, and completed evidence as separate commits.

R5 is resolved at the public Core boundary. This is synthetic lifecycle evidence;
Core Location and native URLSession construction, invalidation, delegates, and
forwarding remain G08/I01 gates. Core cannot interrupt an uncooperative factory,
prevent copied native-reference escape, or validate an author's false quiescence
acknowledgment. Additional unstructured work must have explicit stop/join ownership.
No dependency, native adapter, unsafe isolation annotation, deployment increase,
persistence change, or diagnostic callback is added.
