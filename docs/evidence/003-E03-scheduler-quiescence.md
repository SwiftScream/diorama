# 003-E03: Cancellation, acknowledgements, and scheduler quiescence

- Date: 2026-09-28
- Updated: 2026-09-30 for the owner-authorized async-only delivery and
  phase-name revisions.
- Status: Implementation and local platform verification complete; owner review
  is the next checkpoint.
- Authority: Owner confirmation of E03's scope after outlining the documented
  GPT-6 Astra, `xhigh` recommendation and explaining delivery acknowledgements.
  The owner explicitly authorized stacked development atop E02.
  On 2026-09-29, the owner authorized replacing manual acknowledgement with
  scoped delivery. On 2026-09-30, the owner narrowed that scope to async-only
  delivery and authorized squashing the revision into the implementation commit.
  The owner then requested an unsquashed fixup naming the terminal registration
  phase `completed`.
- Review base: `master`, commit `76cf48b` (merged E02).
- Prerequisites: [E02 evidence](003-E02-deadline-engine-and-handoff.md),
  [B08 evidence](003-B08-concurrent-finalization-and-evaluation.md),
  [DD10](../design-decisions/10-lifecycle-and-ownership.md), and
  [DD14](../design-decisions/14-real-time-replay-scheduler.md).

## Public contract

`SchedulingLease.schedule(at:for:delivery:)` and
`schedule(after:for:delivery:)` each accept one async
`@Sendable () async -> Void` closure. Both forms register synchronously and
return a discardable `ScheduledItemHandle`.
`cancel()` returns true only for the call that cancels pending work. Repeated
calls and cancellation after claim return false. Dropping a handle leaves work
scheduled. Cancellation also causes the worker to reconsider its earliest wait.

Delivery completion follows scope return, including early returns and handled
errors. There is no public acknowledgement token or completion method to forget
or invoke prematurely. Delivery awaits actor hops or other adapter work in an
execution-owned child task without blocking later deadlines. Task submission
follows deterministic handoff order, but body execution and actor arrival order
remain executor-dependent. Adapters establish causal order where a stream needs
it; independent equally due events have no execution-order guarantee.

Scoped return implements DD14's delivery-acknowledgement semantics without
changing its quiescence requirement. The nonthrowing delivery closure leaves
domain error handling with the adapter; registration still throws the typed
`SchedulingFailure`.

Finish closes admission, cancels pending work, joins the active timer and all
claimed delivery tasks before adapter cleanup and result freeze. Concurrent,
repeated, and canceled finish callers retain B08's single-result behavior. A
clock failure cancels pending work while claimed
deliveries retain their completion obligation. New misuse diagnostics can enter
the post-finish log without reopening the scheduler or changing the final result.

The complete usage contract and examples are in
[execution scheduling](../execution-scheduling.md).

## Ownership and race argument

One engine mutex serializes registration, complete due-batch claim, cancellation,
completion, and scheduler closure. Pending items hold callback captures; every
item in a due batch becomes claimed before any handoff. Cancellation removes only
a pending item. It therefore cannot revoke another member of a batch after that
batch's first callback starts. Claim and cancellation have exactly one winner.

Each registration has one pending, claimed, completed, or canceled phase.
Public cancellation handles retain the small registration cell,
which contains only a weak reference to the engine. The cell mutex protects that
weak reference and phase. Handle operations release the cell lock before entering
the engine; transitions take the engine lock before the cell lock. There is no
inverse nested lock order. Terminal transitions clear the weak reference.

The worker owns a structured discarding task group containing asynchronous
deliveries. It continues choosing deadlines while earlier deliveries suspend.
Shutdown joins the timer and exits the drain loop;
leaving the group joins every child before the worker returns. Completed children
are discarded during execution rather than accumulating until finish. Scope
ownership replaces the manual in-flight table and acknowledgement continuation.

Finish may close admission between the drain's initial admission check and its
logical-time read. That read's `executionClosed` result stops the worker normally
instead of reporting a spurious clock failure. Other clock failures cancel
pending work while claimed scopes still drain.

Canceled pending captures are detached and destroyed outside the engine lock,
so destruction may safely reenter scheduling or reporting. Joining delivery
scopes also covers destruction of their captures before finalization freezes
the report. The existing timer identity and closed-state guards reject late
wakes. Escaped terminal handles retain no execution, engine, time service, or
reporter; weak-reference tests prove their release after finalization.

## Proving tests

- Cancel before claim, repeat cancellation, cancel after claim/delivery/finish,
  replace the earliest timer, cancel the last pending item, and ignore a stale
  wake.
- Claim a whole due batch before its first callback attempts cancellation of a
  later member.
- Race two cancellation callers per item against claim for 128 registrations,
  using checked continuations to prove exactly one completion for every item.
- Suspend one async delivery while later timer selection and handoff continue;
  allow deliveries to complete out of order.
- Finish with a suspended async delivery, a pending timer, concurrent finish callers,
  and a caller canceled before or during finish. Deliver on the main actor,
  reject attempted rescheduling, and retain delivery diagnostics before freeze.
- Complete 32 claimed async scopes concurrently during finish and prove every
  registration reaches the completed phase.
- Return early from async delivery, including after handling its own cancellation,
  and prove automatic completion without affecting finish.
- Sort the exact deadline, attachment, track, record, and registration keys used
  for handoff. Prove the batch is claimed before async body execution, without
  asserting an order among independently scheduled bodies.
- Cancel pending async delivery and prove its callback never runs.
- Fail the injected clock with work both pending and in flight; preserve the
  claimed delivery's completion obligation.
- Reenter scheduling from canceled-capture destruction and inspect weak
  ownership after execution release. Report from async capture destruction and
  prove the diagnostic enters the frozen result, not the late log.
- Exercise public APIs without `@testable` from a consumer test module, using a
  real deadline and an actor hop. E02's real-clock no-early-delivery smoke tests
  remain part of the focused and platform gates.

The tests use explicit handoff, timer, cancellation, and capture-release signals
to establish overlap; they do not infer shutdown progress from sleeps or a fixed
number of task yields.

## Verification results

| Gate | Result |
| --- | --- |
| Focused scheduler and public consumer suites | 21 tests pass across five suites. |
| `scripts/check` | Pinned formatting and strict lint pass; all 233 tests, debug/release compilation, example release build, and example execution pass. |
| `scripts/coverage swiftpm macos` | All 233 tests and release builds pass; LCOV exported. |
| `scripts/coverage ios` | Release build and all 233 tests pass on iPhone 17 / iOS 27.0 Simulator with the iOS 18 deployment target; LCOV exported. |
| Pinned Linux reproduction | All 233 tests, release builds, and example execution pass; LCOV exported in the container. |
| Local executable patch coverage against E02 | macOS and iOS each cover 92 of 97 changed executable lines (94.85%), above the 90% patch target. Linux coverage is generated in the ephemeral container but no local line comparison is retained. |
| Documentation and diff | Changed-document local links and anchors resolve; the complete diff against E02 passes `git diff --check`. |

Apple verification uses Xcode 27.0 (`27A266a`) and Apple Swift 6.4
(`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`). Linux uses the canonical
[Apple Container reproduction](../quality-gates-and-ci.md#local-entry-points),
image `swift@sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9`,
`x86_64`, two CPUs, and 4 GB memory. It reports Swift 6.4
(`swift-6.4-RELEASE`) on Ubuntu 24.04. Repository sources are mounted read-only
and copied into the container's working directory.

Compiler and linter warnings remain errors. Xcode emits its metadata-extraction
notice for test bundles without App Intents; the Linux example launcher emits
the previously observed `safeExec` signal 32/33 warnings. These tool messages do
not change the successful compiler, test, or coverage results.

Hosted required CI and Codecov statuses remain integration requirements obtained
through the owner's authorized PR workflow. Local LCOV comparison is review
evidence and does not claim a hosted Codecov result.

## Review boundary and limitations

The review comprises one feature commit containing core scheduling changes,
tests, and the public contract, followed immediately by an unsquashed phase-name
fixup. An evidence/plan-status commit and its adjacent phase-name fixup follow.
The owner authorized folding the earlier async-only review change directly into
the feature commit; the phase-name fixups remain separate for owner review.
There are no dependency, persistence-schema, deployment-floor, unsafe concurrency
annotation, or native-adapter changes.

Adapters must await their owned delivery work within the async scope.
Unstructured tasks and further enqueued callbacks escape that scope unless
explicitly awaited. An async scope that never completes prevents finish from
returning; it must not await the finish that is joining it. Forced termination
and finalization timeouts remain excluded. This boundary does not detect whether
arbitrary consumer tasks are idle, and cancellation does not return selected replay groups
to availability. Grouped lifecycle accumulation remains E04. iOS execution proves
the installed iOS 27.0 runtime with the iOS 18 compile-time floor, not behavior on
an iOS 18 installation.
