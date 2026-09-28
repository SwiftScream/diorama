# Execution scheduling

A system receives an attachment-scoped `SchedulingLease` through
`SystemPreparationContext.scheduling`. After startup completes, it can register
a synchronous handoff at an absolute logical `Duration`, or after a delay from
registration. Every attachment uses the same origin as
[execution logical time](execution-time-service.md).

```swift
let scheduling = context.scheduling

// Later, after execution startup, with a record identity from this attachment:
try scheduling.schedule(after: .milliseconds(25), for: record) {
    deliverSynchronously()
}
```

The record identity provides a declared track and stable local sequence. That
sequence may describe a dynamic operation without a persisted record at that
position. The lease validates track ownership and obtains attachment and track
order from setup. Scheduling neither claims a replay record nor changes track
usage; system behavior owns those operations.

## Time and order

Logical delays map one-to-one onto the execution's `ContinuousClock`. One
worker owns at most one active wait for the earliest deadline. Earlier
registration replaces that wait; later registration preserves it. Timers
request zero tolerance. A wake rechecks logical time before claiming work, so
an early wake cannot cause early handoff. Host load can delay delivery.

Every drain atomically claims the complete currently due batch, ordered by:

1. logical deadline;
2. attachment declaration order;
3. track declaration order and record sequence;
4. atomic registration sequence.

A late wake preserves this ordering across different deadlines. Work registered
during a handoff joins a subsequent batch, including work with an earlier
logical deadline. Handoff order does not impose an execution order on Swift
tasks resumed by the handoffs.

Zero and already-passed deadlines, including offsets before the execution
origin, are queued for the next drain.
Registration never invokes a handoff inline. The worker may run concurrently
with the registering caller, so shared system state still needs its own
synchronization. Handoffs run serially on the concurrent executor, outside
scheduler and execution locks, and may register additional work.

## Ownership and failures

The worker starts with the first accepted registration. Executions that never
schedule work create no scheduler worker or timer. Finish closes admission,
drops pending handoff captures, cancels and joins the active wait, and joins
any claimed synchronous handoffs before system cleanup and report freezing.
An escaped lease cannot reopen the scheduler. A handoff must return and must
not synchronously wait for its own execution to finish.

This initial service tracks a handoff through its synchronous return. Systems
must complete the delivered work within that call. Per-item cancellation and
explicit completion acknowledgements for delivery on another actor or queue
belong to the subsequent scheduler lifetime API in Plan 003's E03 unit.

Negative relative delays, logical addition overflow, and a future deadline outside the host
timer's representable range fail before registration. Invalid tracks, calls
before startup or after closure, backward clock readings, and internal wait
failures produce safe `SchedulingFailure` or asynchronous scheduling diagnostics.
A clock failure stops remaining scheduled delivery. Diagnostics participate in
opt-in `noUnexpectedOperations` evaluation; post-finish facts remain in the
reporter's separate late log. No host instant or underlying clock error enters
the report or scenario data.
