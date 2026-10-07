# Execution logical time

Every successful scenario execution has one monotonic `ContinuousClock` origin.
The origin is captured after all configured systems activate, immediately before
startup returns. All attachments in that execution share the same time service
and one-to-one rate; a later execution has its own origin.

A system receives `ExecutionTime` through `SystemPreparationContext.time`. It
may retain the service in its per-execution dependency. `logicalNow()` returns
the `Duration` since completed startup. `capture()` reserves an observation's
monotonic time and execution-local order. Call it at the observation boundary,
before native extraction or stable conversion that may take time. Later, use
`logicalTime(at:)` or `elapsed(from:to:)` to derive the relative timing that the
system's stable model actually needs. `capturedBefore(_:_:)` compares observation
order even when conversions complete in another order.

Captures are runtime-only tokens. Consumers cannot construct them, and they
have no `Codable` conformance or stable representation. They cannot be combined
across executions. Their order is not a
persisted cross-track ordering constraint. Stable schemas retain only the
capability-specific durations needed to reproduce behavior; synchronous random
observations remain untimed. `logicalTime(after:from:)` adds a nonnegative delay
to a captured anchor with overflow checking, without scheduling delivery.

The service rejects new clock reads before completed startup and after execution admission
closes. A backward clock source, foreign or reversed captures, negative delay,
and unrepresentable duration produce typed failures and safe diagnostics.
Existing tokens can still be inspected after finish; new time observations
cannot be captured. Systems register timed handoffs through the separate
[execution scheduling service](execution-scheduling.md).

## Swift Clock for application code

`DioramaCore.ScenarioClock` conforms to Swift `Clock` over that same execution
origin and deadline engine. Obtain it from `ScenarioExecution.context.clock` or
`SystemPreparationContext.clock`. It is available even in an execution with
no systems. It requires no wall attachment, recording mode, track, or persistence
registration. Monotonic reads and sleeps never add records or usage counts.

`ScenarioClock.Instant` is a `Sendable`, `Hashable`, `Comparable` value whose
`offset` is a signed `Duration`. It has no execution identity or wall value.
An instant with offset five seconds means five seconds after the receiving
execution's startup, including when transferred from another execution.
Negative offsets are already-passed deadlines.

Construction, `advanced(by:)`, and `duration(to:)` enforce a symmetric range
from minus to plus `Int64.max` seconds and 999,999,999,999,999,999 attoseconds.
An operand or result outside that range fails a programmer precondition.
Subnanosecond duration precision is retained; this API does not use the
millisecond wall-persistence codecs. `minimumResolution` retains the host
monotonic source's resolution. Logical deadlines that cannot map into the
host timer's remaining range instead throw a safe scheduling failure.

`sleep(until:tolerance:)` registers with the shared deadline engine. Standard
`Clock` conveniences such as `sleep(for:)` and `measure` work through this
conformance. Past deadlines enter the next drain. Any tolerance, including nil,
uses the scheduler's zero-tolerance policy. The initial scheduler waits in real
time; it does not advance virtual time or guarantee exact task resumption time.

Task cancellation and deadline claim are atomic alternatives. Cancellation of
a pending sleep removes it and throws `CancellationError`. A claimed sleep
completes normally, including if cancellation arrives before its continuation
resumes. Finish cancels pending sleeps and joins claimed handoffs, but does not
join the application tasks resumed by those handoffs.

Finish stamps the logical horizon while excluding new time reads and closing
admission, before waiting for scheduler quiescence. A later `now` reports
`logicalTime(executionClosed)` and returns that frozen horizon. A new sleep
reports and throws `SchedulingFailure` with `scheduling(logicalTime(executionClosed))`,
even when its deadline is in the past or its calling task is already canceled.
These facts have scenario context, with no invented attachment or record.
Post-finish diagnostics remain in the separately retained reporter; they never
change the immutable result.

An unavailable active `now` reports its safe time issue and returns the last
valid instant, or zero before startup. Failure to establish the final horizon
invalidates the recording candidate. Timer failures resume pending sleeps with
the already-reported `SchedulingFailure`. Escaped clock values keep their
small frozen time state and reporter while releasing the native source and
holding only a weak reference to the scheduler.

The ownership boundary is recorded in
[DD15's execution-clock amendment](design-decisions/15-clock-system.md#execution-clock-ownership-amendment--owner-approved-2026-10-07).
`DioramaClock` separately records and replays wall `Date` observations.

## Scoped consumer access

The `Diorama` facade's single `execute` operation always passes a
`ScenarioExecutionContext` first, followed by configured system dependencies
in declaration order. The context currently exposes only `clock`. It is an
immutable, `Sendable` value constructed by Core for each execution; retaining
it does not extend execution lifetime or retain adapters. System preparation
keeps its separate attachment-specific `SystemPreparationContext`.
The closure keeps its inferred actor isolation and the ordinary
result/finalization policy. Bodies that need only dependencies may ignore
the context parameter with `_`.
No Core import is needed when these values are inferred:

```swift
import Diorama

let setup = try Diorama(scenarioID: "retry-backoff", mode: .record)
let result = try await setup.execute { context in
    let start = context.clock.now
    try await context.clock.sleep(for: .milliseconds(25))
    return start.duration(to: context.clock.now)
}
```

Pass the clock to application code that accepts a generic Swift `Clock` for
timeouts, retry delays, or debounce behavior. Sleeps use real elapsed time in
this implementation. The returned definition in this example contains no
attachments, and the usage report has no clock operations. Finishing the scope
cancels any pending sleeps even when the body fails or is canceled.
