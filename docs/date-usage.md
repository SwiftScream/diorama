# Date observations and execution time

Use `DioramaDate` when application code needs recorded dates. Use the Core
execution clock when application code needs elapsed time, retry delays, or
application timeouts that share the replay scheduler. Both are available in a
scoped `Diorama` body:

```swift
import Diorama
import DioramaDate

let wall = try DioramaDateSystem.instance(named: "device-wall")
let setup = try Diorama(scenarioID: "retry", mode: .record, systems: wall)
let result = try await setup.execute { context, wall in
    let firstDate = wall.now
    try await context.clock.sleep(for: .milliseconds(2))
    return [firstDate, wall.now]
}
```

The injected dependency conforms to `DioramaDateSource`, a `Sendable` protocol
whose synchronous, nonthrowing `now` property returns `Date`.
`DioramaDate` replaces the former `DioramaClock` module and public type names.
Existing wall recordings must change their system `type` from `diorama.clock`
to `diorama.date`; see the [schema reference](date-schema-v1.md#former-system-identifier).
No compatibility aliases or automatic migration are provided.

The two dates are wall observations. The delay is an execution operation.
Recording returns native `Date` values while independently rounding persisted
observations to milliseconds. Replay returns those prepared dates, including
repeated or backward values, without reading the live source. Sleeps use the
execution's shared monotonic scheduler in every attachment mode.

Application code can accept the standard Swift `Clock` protocol:

```swift
func retryDelay<C: Clock>(using clock: C) async throws
    where C.Duration == Duration
{
    try await clock.sleep(for: .milliseconds(2))
}
```

A wall adjustment can move the next date backward while the retry delay still
advances monotonic execution time. Neither a wall delta nor an authored origin
changes when a timed system delivers an event. Delays initially map one-to-one
to real monotonic time; execution time does not advance virtually.

The compiled [date example](../Examples/Sources/DioramaDateUsage/main.swift)
records observations across a retry delay to a temporary file, replays it
without further live reads, and checks that replay leaves the file unchanged.
It also runs a delay without a wall attachment. Run it with:

```sh
swift run --package-path Examples DioramaDateUsage
```

## Clock-only and empty-wall execution

Application delays require no `DioramaDate` import, system declaration,
persistence registration, or wall payload:

```swift
import Diorama

let setup = try Diorama(scenarioID: "retry-only", mode: .record)
let result = try await setup.execute { context in
    try await context.clock.sleep(for: .milliseconds(2))
}
```

Its definition has no attachments and its usage is empty. In a file-backed
run, publication is requested by recording attachments. A run with no systems
can use an existing empty scenario document but does not publish a new file.
Execution-clock reads and sleeps never create content to persist.

A declared wall system that records no reads publishes an explicit empty wall
payload. Replay of that payload may use the execution clock without consuming
wall values. Calling `wall.now` instead exhausts the empty recording, reports
an unexpected replay operation, and returns Unix epoch if the configured
handler returns. A declared replay wall whose track is missing remains a setup
error. See the [wall schema](date-schema-v1.md).

## Several walls and attachment modes

Declare independent wall sources with different attachment names. Each owns
its source and sequential observation cursor. One can record while another
replays and a third passes through. Replay never invokes its live source
factory, and passthrough never changes baseline wall content. Setup is reusable;
each execution has fresh cursors and a fresh execution-clock origin.

All handles obtained from `ScenarioExecution.context.clock`,
`SystemPreparationContext.clock`, and the `execute` body context use that execution's
scheduler. Applications can exchange deadlines with their systems as logical
offsets. A transferred instant means the same offset from the receiving
execution's origin; it carries no execution identity or wall date.

Concurrent wall reads acquire one serialized observation order per attachment.
Which racing task receives each value is not reproducible. Coordinate calls
when their assignment matters, or use separately named walls for independent
domains. Concurrent execution-clock sleeps also have no application task
resumption-order promise. Equal-deadline scheduling determines handoff order,
with attachment work before clock sleeps, as described in
[execution scheduling](execution-scheduling.md).

## Editing and re-recording

The [version-one schema](date-schema-v1.md#re-recording-authored-overrides)
uses one origin and signed successive deltas. Author an `override` to shift the
origin or a later observation. A later delta override shifts that observation
and subsequent values. Regional timezone rules are not persisted: an origin
retains its representable numeric UTC offset.

Re-recording derives fresh deltas before preserving applicable baseline
overrides. Correspondence is positional, so inserting a read can move an old
override to a different call site. Overrides beyond the new sequence length
are dropped. Recording no reads removes all old wall content. Replay and
passthrough attachments retain their baseline content during mixed-mode
publication. The [composition golden](../Tests/DioramaDateTests/Fixtures/date-composition.json)
shows separately keyed authored, repeated, backward, and empty wall data.

Record mode captures `TimeZone.current` at activation and selects the numeric
offset at the first observation. Setup does not expose a separate encoding-zone
option. An authored whole-origin override retains its own date and offset.
Native submillisecond observations may therefore differ from replay by the
millisecond rounding rule. Unsupported source values diagnose conversion
failure and make the recording candidate unhealthy while returning the native
observation to the live caller.

## Timeouts and finish

Use a structured task group to race application work against a clock sleep,
then cancel the losing task. Clock cancellation does not undo a system's replay
claim or mark an unfinished interaction consumed. System adapters own that
cancellation and acknowledgement policy. The
[synthetic composition tests](../Tests/DioramaDateTests/DateSchedulingConformanceTests.swift)
exercise timed batches followed by a response alongside an application timeout.
They also prove that a claimed delivery can finish its acknowledgement while
shutdown waits for it.

Finish cancels pending sleeps, joins claimed system delivery, and freezes the
execution clock at its admission-closing horizon. A claimed sleep completes
normally. The scheduler joins sleep handoffs; it does not join application work
that runs after a sleep resumes. Await application tasks within their scope.
Escaped wall and execution-clock handles diagnose use after closure. Wall reads
repeat their last value or Unix epoch, execution `now` returns the frozen
horizon, and a new sleep throws an execution-closed scheduling failure.

The portable clock contract is tested on macOS, iOS Simulator, and Linux.
The scalar and wall/composition suites also run on iOS 18.0; this targeted
minimum-runtime check supplements the full current-simulator run. The macOS 15
floor is verified through compilation, with runtime checks on the current OS.
The [conformance evidence](evidence/003-F07-clock-composition-conformance.md)
records the actual platform runs, retained scalar goldens, and limitations.
