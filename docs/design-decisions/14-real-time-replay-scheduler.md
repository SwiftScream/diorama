# Decision 14: Initial real-time replay scheduler

- Status: Accepted
- Last updated: 2026-09-06
- Depends on: [Decision 1: Common abstraction](01-common-abstraction.md),
  [Decision 2: Shared and system-specific semantics](02-shared-vs-system-semantics.md),
  [Decision 3: Recorded behaviors](03-recorded-behaviors.md),
  [Decision 5: Consumption and verification](05-consumption-and-verification.md),
  [Decision 6: Runtime-to-snapshot conversion](06-runtime-to-snapshot-conversion.md),
  [Decision 10: Lifecycle and ownership](10-lifecycle-and-ownership.md), and
  [Decision 13: Random proving system](13-random-proving-system.md)

## Decision

How does the initial scheduler map recorded timing to runtime delivery, order
simultaneous work, coexist with live recording, expose scheduling to systems,
and stop safely at finalization?

## Context

Earlier discussion used "automatic logical time" ambiguously. It was initially
documented as accelerated virtual time that jumped to the next deadline without
waiting. The intended initial behavior is instead one-to-one real-time replay:
an effective delay of 250 milliseconds waits approximately 250 milliseconds.

That distinction removes the need to detect whether all arbitrary Swift tasks
are suspended before advancing virtual time. The scheduler still needs common
deadline ordering, cancellation, native delivery handoff, and strong lifecycle
ownership, but it can build those semantics on a monotonic real clock.

Decision 3 also now makes persisted timing capability-specific. The scheduler
does not expect every track record to have a timestamp. It schedules only
behavior whose elapsed time is observable during replay.

## Terms

- **Logical time** is a `Duration` from the start of one scenario execution.
- **Execution origin** is the runtime-only monotonic instant captured when the
  execution starts.
- **Effective delay** is the recorded or authored-override duration selected
  for a replay behavior.
- **Deadline** is the runtime-only monotonic instant obtained by mapping a
  logical time through the active playback policy.
- **Idle** means the scheduler currently has no pending or in-flight work.
- **Quiescent** is a final shutdown guarantee: the execution accepts no new
  work and no Diorama-owned callback can occur later.

Idle is transient and does not imply that application tasks have finished.
Quiescence is used only for system and execution shutdown; it is not a claim
that all Swift tasks in the process are suspended.

Owner-approved clarification, 2026-09-06: the callback guarantee concerns
Diorama-owned scheduled delivery and observation. A new call to an escaped
dependency may still produce a diagnostic sink notification under
[Decision 10's post-finish reporting contract](10-lifecycle-and-ownership.md#post-finish-reporting-lifetime--2026-09-06).
That notification does not reopen admission or restart the scheduler.

## Initial playback policy

The initial policy is **real-time automatic** playback. Logical duration maps
one-to-one to monotonic real duration:

```text
real delay = effective logical delay
```

The execution captures one origin when startup completes. Its `logicalNow` is
the monotonic duration from that origin. The scheduler waits until the mapped
real deadline rather than jumping logical time forward.

An authored timing override follows the same mapping. A 12-second override
therefore takes approximately 12 real seconds. This is intentional even though
it can make a test slower; the override asks Diorama to reproduce slow behavior.

## Monotonic clock and precision

The initial scheduler uses Swift's `ContinuousClock`. Its instants are
runtime-only and never persisted or compared between executions. Stable
snapshots contain portable nonnegative `Duration` values.

The scheduler requests zero timer tolerance for replay deadlines. It guarantees
that it will not deliberately deliver behavior before its deadline. Operating
system timer resolution, load, and executor scheduling may make delivery late,
so Diorama does not promise hard real-time precision or exact elapsed equality.

Tests should primarily assert behavior and order. Timing integration tests use
bounds wide enough for supported CI platforms rather than treating normal
scheduler latency as a failure. Diorama does not persist replay lateness or
silently rewrite effective fixture timing from it.

The concrete clock is internally injectable so the deadline engine can be unit
tested without long waits. This is testability of the implementation, not an
initial public virtual-time policy.

## Timing origins

Capability-specific behavior maps onto the execution timeline as follows:

- A synchronous demand-driven observation returns immediately and does not
  register scheduler work.
- An interaction invocation anchors its relative phase and conclusion offsets
  to `logicalNow` at invocation.
- A stream subscription anchors its publication offsets to `logicalNow` at
  subscription.
- A clock sleep registers a deadline at `logicalNow + requestedDuration` or the
  equivalent absolute logical deadline.

Each interaction and subscription has its own anchor. Starting the same
recorded behavior later in the scenario shifts all of its deadlines together;
it does not attempt to reproduce incidental absolute chronology from the
recording run.

## Deadline engine

One execution-owned deadline engine maintains pending scheduled items and one
active wait for the earliest deadline. Registering an earlier item wakes and
replaces that wait. Cancelling the earliest item likewise causes the engine to
select the next pending deadline.

When the timer wakes, the engine atomically claims all currently due items in
defined order, marks them in flight, and then hands them to their systems
outside scheduler isolation. A late wake may make several different deadlines
due together; their original deadline ordering is still preserved.

A registration whose deadline is already due is queued for the next drain. It
is never delivered synchronously inside the registration call. This prevents
reentrant callbacks before the registering system has stored its handle or
completed its own state transition.

Negative stable delays and duration arithmetic overflow are invalid scenario
data diagnosed during loading or setup. A runtime request for an already passed
clock deadline follows the same next-drain rule rather than becoming corrupt
data.

## Equal-deadline ordering

Scheduled items sort by:

1. deadline;
2. attachment order from the scenario definition;
3. stable track and record sequence within that attachment;
4. atomic registration sequence as the final tie-breaker for dynamically
   equivalent items.

The engine claims the complete due batch before handing off any delivery. It
can guarantee handoff order, but Swift does not guarantee that two resumed tasks
execute in continuation-resume order. A test must not derive meaning from which
of two logically simultaneous racing tasks runs first.

Exact cross-track causality is not inferred from equal timestamps. The explicit
setup-time coordination mechanism deferred by decision 1 may later impose a
stronger relation.

## Registration and cancellation

A system registers:

- a logical deadline or delay;
- its delivery operation;
- stable ordering information supplied by its attachment context.

Registration returns an execution-owned cancellation handle. A scheduled item
has mutually exclusive pending, claimed-for-delivery, delivered, and cancelled
states. Cancellation is idempotent and races atomically with claiming, so
exactly one wins. Delivery and continuation resumption never occur while the
scheduler's state isolation is held.

System adapters translate cancellation to their native contract. A cancelled
clock sleep throws `CancellationError`; a cancelled replay URLSession task
stops future replay callbacks. Caller cancellation remains runtime control and
is not added to the stable recording.

## System behavior

### Synchronous observations

Random values, synchronous clock observations, and similar demand-driven values
do not enter the deadline engine. They record or consume their system-defined
sequence immediately.

### Interactions

An invocation establishes an anchor and its phases and conclusion retain
offsets from that anchor. A phase may also have a lifecycle prerequisite. It
becomes deliverable only when both its recorded deadline is due and its current
prerequisite has completed.

For example, a final HTTP response recorded at one second cannot precede the
current redirect decision. If the decision completes before one second, the
response waits for its recorded deadline. If the decision completes after one
second, the overdue response is queued for the next drain and is not delivered
reentrantly from the decision callback.

Conditional branches register only behavior reachable through the current
phase decision. An open interaction schedules its recorded phases but no
terminal outcome, then remains pending until caller cancellation or scenario
finalization.

### Streams

A stream subscription establishes an anchor. Publications become due at their
subscription-relative offsets. Cancellation removes remaining registrations.
An open stream delivers all recorded publications and remains active without a
synthetic completion.

### Clock sleeps

A sleep uses the scenario scheduler rather than starting an unrelated timer.
It completes at its logical deadline or throws on cancellation. Detailed clock
operation recording belongs to decision 15.

### Record and passthrough

Native dependencies control record- and passthrough-mode delivery. Record-mode
systems use the execution clock only to derive behaviorally meaningful stable
delays at the native observation boundary. They do not route native callbacks
through the replay deadline engine merely to make modes look uniform.

## Mixed modes

Every attachment in one execution observes the same `ContinuousClock` origin
and one-to-one rate:

- record-mode systems derive meaningful relative observations from it;
- replay-mode systems map effective delays onto it;
- passthrough systems do not retain track timing but coexist on it.

Per-attachment modes do not create separate clocks or playback rates. Replay
delivery does not pause, jump, or otherwise distort elapsed time captured by a
live recording attachment. This is substantially simpler than mixing live time
with an accelerated virtual scheduler.

## System extension surface

First-party and consumer-defined systems receive a narrow execution-scoped
scheduling service that can:

- read logical time as `Duration` since scenario start;
- capture monotonic time for deriving stable record-mode delays;
- register delivery at a logical deadline or after a logical delay;
- cancel work through a returned handle;
- acknowledge completion of a handed-off delivery.

Attachment identity and ordering metadata come from the system context rather
than being caller-supplied strings. The service does not expose
`ContinuousClock.Instant`, timer internals, public time advancement, or an
initial playback-rate setting. Its lease refuses scheduling after the owning
attachment closes.

Systems choose the actor, queue, event loop, or native callback context required
for actual delivery. The scheduler tracks the handoff as in-flight until the
system acknowledges completion, but does not require every integration to
execute consumer callbacks on one Diorama actor.

## Finalization

Scheduler shutdown participates in decision 10's asynchronous, idempotent
execution finalization:

1. stop accepting new registrations and capture the recording horizon at
   current logical time;
2. cancel the active timer and all pending replay registrations;
3. allow already claimed deliveries to complete without accepting follow-up
   scheduling;
4. wait until no Diorama-owned delivery callback is executing;
5. detach live record-mode observation without cancelling consumer-owned live
   operations;
6. freeze lifecycle progress and verification results.

An execution generation and closed-state check make a late timer wake-up a
no-op. Finalization returns only after the scheduler and every adapter report
quiescence, so no Diorama-owned callback can escape afterward. Repeated finish
calls await the same finalization result.

A selected replay group is not returned to the unused pool when finalization
cancels its remaining scheduled phases. Verification reports the lifecycle
progress it actually reached.

Diorama cannot forcibly stop synchronous consumer code. A consumer callback
that never returns can prevent quiescence. A future configurable finalization
timeout may diagnose that condition, but cannot make unsafe termination sound.

## Future playback rates

Stable snapshots always store unscaled logical durations. Constant-factor
acceleration is the leading next scheduler enhancement:

```text
real delay = effective logical delay / playback rate
```

Keeping mapping in the scheduler allows such a rate to preserve relative
ordering without rewriting snapshots. Rate validation, rounding, extremely
small delays, and mixed live/replay semantics require their own follow-up
decision before this becomes public API.

Manual advancement and fully virtual automatic time are separate capabilities.
Fully virtual time reintroduces the problem of knowing when participating tasks
have registered work before the clock jumps, so it must not be treated as merely
an infinite playback rate.

## Verification

The scheduler requires focused tests for:

- deadline and equal-deadline ordering;
- zero and already-due delays without registration reentrancy;
- earlier-deadline insertion and timer replacement;
- cancellation racing with deadline claiming;
- lifecycle prerequisites and overdue conditional phases;
- stream subscription anchors and interaction invocation anchors;
- mixed record/replay timing;
- finalization during pending and in-flight delivery;
- no callback after quiescence;
- macOS, iOS Simulator, and Linux real-clock integration.

Unit tests use the internal injected clock. A small real-clock suite validates
platform integration with tolerant elapsed bounds and must not rely on precise
executor latency.

## Consequences

Benefits:

- Initial replay timing matches ordinary real-time intuition.
- Timeout and response deadlines coexist without global task-quiescence
  detection.
- One engine provides deterministic handoff order and lifecycle cleanup.
- Mixed record and replay attachments share a natural monotonic timeline.
- Systems receive portable `Duration` APIs rather than runtime clock instants.
- Persisted delays remain suitable for later constant-factor scaling.

Costs:

- Tests wait for recorded or overridden durations.
- Delivery can be later than requested under host load.
- Simultaneous continuation execution remains subject to Swift executor
  scheduling even though Diorama handoff order is stable.
- Conditional lifecycles require both deadline and prerequisite state.
- Systems must acknowledge delivery completion for strong finalization.

## Explicit non-decisions

This decision does not determine:

- a public playback-rate API;
- constant-factor rounding and mixed-mode policy;
- manual or fully virtual time advancement;
- explicit cross-track coordination constraints;
- the initial clock system's complete native and stable API;
- a forced termination mechanism for consumer callbacks;
- exact Swift declaration names or scheduler data structures.

## Review questions

1. **Initial time policy: Resolved.** Logical time maps one-to-one to monotonic
   real time. Constant-factor acceleration is the leading next enhancement;
   fully virtual time is future work.
2. **Timing origins: Resolved.** Execution, interaction invocation, stream
   subscription, and clock sleep establish the relevant logical origins.
3. **Clock and tolerance: Resolved.** Use runtime-only `ContinuousClock`
   instants and request zero timer tolerance without promising exact wake time.
4. **Equal deadlines: Resolved.** Sort by deadline, attachment order, stable
   local sequence, then registration sequence, while distinguishing handoff
   order from task execution order.
5. **Registration and cancellation: Resolved.** Registrations are
   execution-owned, non-reentrant, cancellable state machines with atomic
   claim-versus-cancel behavior.
6. **Mixed modes: Resolved.** All attachments share one origin and rate;
   replay scheduling cannot distort live monotonic capture.
7. **System mapping: Resolved.** Synchronous observations are immediate;
   interactions, streams, and sleeps register capability-specific deadlines;
   conditional phases also wait for their prerequisites.
8. **Finalization: Resolved.** Close admission, cancel pending work, finish
   claimed delivery, and return only after Diorama-owned callbacks are
   quiescent.
9. **Extension surface: Resolved.** Systems receive portable logical-time,
   scheduling, cancellation, and delivery-acknowledgement services without
   public timer or advancement controls.

## Accepted answer

Diorama initially maps logical time one-to-one onto an execution-owned
`ContinuousClock`. Capability-defined effective delays wait for their real
duration. A single cancellable deadline engine orders work deterministically,
hands delivery to systems outside its isolation, and tracks it through
completion.

Interactions anchor phases and conclusions to invocation, streams anchor
publications to subscription, and clock sleeps register from current logical
time. Conditional phases require both their deadline and lifecycle prerequisite.
Synchronous demand-driven values do not use the scheduler.

All attachment modes share one clock origin and rate. The public system
extension boundary exposes portable `Duration` scheduling but not clock
instants or time controls. Finalization cancels pending work and establishes
quiescence before returning. Stable durations remain unscaled so a separately
designed constant-factor playback rate can be added later.
