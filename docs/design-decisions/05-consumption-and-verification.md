# Decision 5: Consumption and verification

- Status: Accepted
- Last updated: 2026-09-05
- Depends on: [Decision 1: Common abstraction](01-common-abstraction.md),
  [Decision 2: Shared and system-specific semantics](02-shared-vs-system-semantics.md),
  [Decision 3: Recorded behaviors](03-recorded-behaviors.md),
  [Decision 4: Replay selection](04-replay-selection.md)

## Decision

Does replay consume recordings, and how are unused or unexpected recordings
reported when a scenario execution ends?

## Context

Decision 4 separates candidate selection from consumption state. A selector
compares a live operation with recorded behavior, while the replay coordinator
decides which candidates remain available during one execution.

Without consumption, repeated equivalent requests always select the same
result. A recording containing two identical requests with different responses
cannot replay the sequence that was observed. It also becomes impossible to
detect an extra third request reliably.

Consumption and verification are related but distinct:

- **Consumption** changes in-memory availability during one replay execution.
- **Verification** evaluates what happened during that execution and produces
  structured diagnostics.
- Neither operation modifies the persisted scenario.

The core reports facts about replay usage; it does not decide whether those
facts pass or fail a test. Consumers can inspect the report or deliberately
invoke a helper that evaluates selected conditions.

Diorama records and supplies dependency behavior. It is not a general mock
framework for asserting every action taken by application code. In particular,
decision 3 established that caller cancellation is not recorded, injected, or
verified. Consumption must retain that boundary.

## Unit of consumption

The default unit of consumption should be the complete grouped behavior chosen
by a selector:

| Capability | Consumed unit |
| --- | --- |
| Interaction | One grouped invocation, its phases, and its conclusion. |
| Stream | One grouped subscription and its complete delivery lifecycle. |
| Clock | One grouped clock operation, such as an observation or sleep. |
| Custom system | A stable grouped unit declared by the system. |

The group is claimed when the live operation selects it, not when its conclusion
is delivered. Its lifecycle events then advance within that private claim and
cannot be selected by another operation.

For example, selecting an HTTP interaction claims its redirect and
authentication phases as well as its final response. Starting a location
subscription claims the subscription group; its individual location values are
scheduled events within that claim, not candidates available to another
subscription.

This also applies to `openAtRecordingHorizon`. An open interaction or stream is
used once it has been selected even though it has no terminal result.

## Single-use default

Every grouped recording is available once during a scenario execution by
default. A successful selection atomically changes it from available to
claimed. It never returns to the available pool during that execution.

This produces useful behavior for repeated equivalent interactions:

```text
recorded: GET /updates -> version 1
recorded: GET /updates -> version 2

replay call 1 -> claims the first recording -> version 1
replay call 2 -> claims the second recording -> version 2
replay call 3 -> fails: matching recordings exist, but both are exhausted
```

The selector still owns equivalence and ordering. Consumption only filters or
annotates candidates with their current availability. An exhaustion diagnostic
is more useful than a generic no-match diagnostic because it can explain that
the input was recognized but occurred too many times.

The initial first-party capabilities should not silently reuse the final match
or loop a sequence. Such behavior can hide an unexpected extra operation. A
future explicit cardinality or reusable-recording policy can be added for a
concrete need, but reuse is not part of the initial behavior.

## Atomic claims and concurrency

Selection and claim must be one atomic coordinator operation. If two equivalent
HTTP requests arrive concurrently, they must not both receive the same
available recording.

Conceptually:

```text
1. obtain candidates within the keyed system attachment
2. apply the system selector to candidates and availability state
3. validate the selection
4. claim the selected group
5. return a private replay handle for its lifecycle
```

The concrete synchronization mechanism is deferred. It may be an actor, a
lock-protected ledger, or another implementation appropriate to the package's
platform and concurrency requirements. The observable claim order must be
deterministic for a given order of operations reaching the coordinator.

A claim is not rolled back if the application cancels, abandons the operation,
or responds incompatibly to a later phase. Reoffering it could cause another
operation to receive behavior that had already begun. An incompatible
continuation remains the immediate structured failure defined by decision 4.

## Lifecycle progress is not separate consumption

The coordinator may track lifecycle progress for scheduling, diagnostics, and
cleanup, but phases and conclusions are not separately counted as unused
recordings.

This distinction matters when a test ends while selected work is still active:

- A selected HTTP interaction is used even if its delayed response has not yet
  been delivered.
- A selected location stream is used even if the test stops observing before
  every future recorded update is scheduled.
- A selected `openAtRecordingHorizon` behavior is used and remains open by
  design.
- A caller cancellation does not make the recording unused and is not itself a
  failing condition imposed by Diorama.

Diorama should include active or partially replayed claims as diagnostic
context, including how far a stream progressed and whether a recorded terminal
conclusion was reached. This diagnostic does not change the group's used state.
Requiring every selected lifecycle to reach its recorded conclusion is an
opt-in consumer assertion because it tests application control flow beyond
basic dependency selection.

## Unexpected operations

An operation is unexpected when replay cannot supply a unique available
recording. Important cases include:

- no recorded input matches;
- matching recordings exist but are already claimed;
- the selector cannot resolve multiple candidates;
- a selected interaction has no continuation compatible with a later live
  decision;
- a live operation targets a missing or incorrectly configured attachment.

The coordinator must record the diagnostic as soon as the condition is
detected. If the native operation has a failure channel, the system should also
complete that operation with a distinct Diorama infrastructure error. This is
not a recorded domain failure and does not directly invoke a test framework.

Not every native API can express failure. A clock observation may be a
nonthrowing property, and starting a delegate-based location service may return
`Void`. The common core therefore cannot promise that every unexpected
operation returns or throws an error. Each such system must define an explicit,
documented, deterministic continuation policy that does not contact the live
dependency or disguise the problem as a recorded domain failure. The concrete
policy belongs to that system's design.

The coordinator should also retain each diagnostic in its execution ledger.
This allows the final report to include it even if application code catches or
otherwise loses the immediate error.

## Unused recordings

At verification time, every grouped recording that remains available is
unused. The report should identify every unused recording in an attached replay
system by default, without assigning a test outcome to it.

This makes the scenario usage visible. It highlights removed HTTP calls,
subscriptions that no longer start, and clock observations that no longer
occur, while leaving the consumer to decide whether those facts matter to a
particular test.

The core should provide framework-independent, explicitly invoked evaluation
helpers. Conceptually, a consumer could choose any of these policies:

```text
report.requireNoUnexpectedOperations()
report.requireAllRecordingsUsed()
report.requireAllSelectedRecordingsCompleted()
```

These names are illustrative. A helper may throw a structured evaluation error
or return an evaluation result; it must not implicitly call XCTest or Swift
Testing. Helpers should support evaluating a whole scenario or selected system
attachments. The lifecycle-completion helper is deliberately separate because
it opts into checking behavior Diorama does not otherwise enforce.

More granular optional groups, reusable recordings, or minimum and maximum
cardinalities should be deferred until a concrete use case demonstrates the
required model.

Record and passthrough attachments are not expected to consume existing
recordings. In a mixed-mode scenario, unused replay diagnostics apply only to
replay attachments.

## Unattached recorded systems

A persisted track whose system attachment is absent cannot be verified or
interpreted by that system. Silently ignoring it would be indistinguishable
from accidentally forgetting to configure a dependency.

The recommended default is to diagnose recorded system keys that are not
attached during setup. A consumer who intentionally uses only a subset of a
scenario can name the ignored attachments explicitly. The exact setup API and
the point at which this check runs belong to decision 10.

## Verification report

The core should aggregate a structured report rather than emit test-framework
failures directly. A conceptual report contains:

```swift
struct ScenarioVerificationReport {
    var issues: [VerificationIssue]
    var usageByAttachment: [AttachmentUsage]
}
```

This is not a final Swift API. The report must be sufficient for a testing
integration, assertion helper, or caller to render:

- unexpected live operations and continuation mismatches;
- ambiguous selections;
- exhausted matching recordings;
- unused recording groups;
- recorded tracks that were not attached or explicitly ignored;
- lifecycle progress for every selected claim, including incomplete and
  open-by-design states;
- the system attachment key, track, stable record identity, and safe domain
  description relevant to each issue.

Diagnostics should preserve deterministic ordering: attachment order, track
order, then recording sequence where possible. Domain systems can contribute
safe comparisons, such as an HTTP request difference, without the core needing
to understand their values.

The report itself has no overall passing or failing status. The core must not
depend on XCTest or Swift Testing. A consumer may use a framework-independent
evaluation helper and decide how its result affects a test. Whether report
finalization is explicit or tied to a scoped scenario helper is a lifecycle
question for decision 10.

## Diagnostic delivery and testing integrations

The execution ledger and final report are authoritative, but consumers should
not need to wait until finalization to learn that replay cannot continue an
operation. Scenario setup may install a diagnostic sink that is notified after
each diagnostic has been recorded. Conceptually:

```swift
protocol DioramaDiagnosticSink: Sendable {
    func record(_ diagnostic: DioramaDiagnostic)
}
```

This is not a final API. A closure-backed convenience should make custom use
small, while a protocol or equivalent type erasure leaves room for reusable
integrations. Notification must be safe when operations report diagnostics
concurrently, and a sink cannot prevent a diagnostic from entering the ledger.

The package may provide separate opt-in integration products for XCTest and
Swift Testing. A consumer could install one during setup to map selected
diagnostic categories to `XCTFail`, `Issue.record`, or their future equivalents.
Such an integration may capture the test source location at setup and must make
its reporting policy explicit. The core remains independent of both testing
frameworks and never installs an integration implicitly.

A fail-fast sink that traps on a serious diagnostic can be a debugging
convenience, but should not be the recommended test integration: trapping can
terminate the process, prevent other tests from running, and lose the benefit
of an aggregate report.

Immediate notification remains separate from continuation behavior. Recording
a test issue does not produce the value required by a nonthrowing clock
observation, for example. The system-specific deterministic continuation policy
still applies after the sink is notified.

## Modes and execution scope

Consumption belongs to one in-memory scenario execution:

- Loading the same persisted scenario into a new execution resets every
  recording to available.
- Replaying never writes consumption state back to persistence.
- Record mode produces observations rather than consuming existing recordings.
- Passthrough mode neither consumes nor verifies recordings.
- Per-system mode overrides preserve these rules independently within each
  attachment.

This keeps tests isolated and allows parallel test processes to read the same
scenario safely, subject to the persistence behavior chosen later.

## Worked examples

### Reordered HTTP requests

The recording contains `GET /profile` followed by `GET /weather`. Replay starts
them in the opposite order. The HTTP selector uniquely matches and atomically
claims each recording. The report identifies both as used despite their changed
arrival order.

### Repeated identical HTTP requests

Two equivalent `GET /updates` recordings return different versions. Each replay
call claims the earliest available equivalent recording. Because HTTP has a
failure channel, a third call receives an infrastructure error and the
exhaustion diagnostic remains in the report. If the test makes only one call,
the report identifies the second recording as unused. The consumer decides
whether to assert on either fact.

### Location stream stopped by the caller

A location subscription recording contains five timed updates and is open at
the recording horizon. Starting the service claims the subscription group. If
the application stops observing after two updates, the group remains used;
Diorama does not assert the cancellation or mark the remaining values as unused
recordings. Its lifecycle progress still appears in the report.

### Clock operations

A clock attachment contains three recorded `now` observations. Each call claims
the next compatible operation. If only two occur, verification reports the
third grouped clock operation as unused. Another keyed clock attachment has an
independent ledger.

### Unused system attachment

A scenario contains `api`, `device-location`, and `device-clock`. A test attaches
all three for replay but never starts location updates. The recorded location
subscription appears as unused in the report. A test concerned only with HTTP
can inspect that fact without treating it as a failure, while a test expecting
exact scenario use can invoke the all-recordings-used helper.

## Recommendation

Use atomic, single-use claims of complete grouped recordings. Repeated
equivalent operations advance through available recordings in deterministic
recorded order. Diagnose an excess operation immediately and propagate a
distinct infrastructure error when the native API supports failure. Require an
explicit system-specific continuation policy when it does not.

At the scenario boundary, report which recordings belonging to replay systems
were unused and which selected lifecycles remain incomplete. Aggregate these
facts and unexpected operations in a structured, test-framework-independent
report. Treat a selected group as used without asserting that every internal
lifecycle phase completed. Provide opt-in evaluation helpers so consumers can
turn the conditions relevant to their tests into failures themselves.

## Consequences

Benefits:

- Repeated equivalent interactions can reproduce different successive results.
- Unexpected extra and missing operations are both detectable.
- Atomic claims support concurrent callers without duplicate reuse.
- Cancellation remains outside Diorama's verification responsibility.
- Consumers retain control over which replay facts affect their tests.
- Serious replay problems can be surfaced promptly through an opt-in sink.

Costs:

- Replay requires concurrency-safe per-execution state.
- Consumers seeking exact usage must explicitly invoke an evaluation helper.
- Claiming a group at selection does not detect every abandoned or incomplete
  application operation.
- Reusable stubs and detailed cardinality constraints require later extension.

## Explicit non-decisions

This proposal does not determine:

- the concrete ledger, claim handle, or verification report types;
- the lock or actor strategy used for atomic selection and claim;
- how verification is tied to a test or scenario lifecycle;
- how source locations are captured for test-framework diagnostics;
- concrete diagnostic sink and optional testing-integration APIs;
- the continuation policy for each non-failable native API;
- per-record optionality, reusable recordings, or cardinality ranges;
- how persisted recording identifiers and occurrence keys are encoded;
- persistence behavior for concurrent recording processes.

## Review questions

1. **Consumption unit: Resolved.** A complete grouped interaction,
   subscription, or clock operation is atomically claimed once at selection,
   including a group whose conclusion is `openAtRecordingHorizon`. Its internal
   lifecycle belongs exclusively to that claim and is not consumed separately.
2. **Lifecycle completion: Resolved.** Selection makes the whole group count as
   used even when its later phases or conclusion are not reached. The report
   still highlights lifecycle progress and incomplete conclusions without
   indirectly verifying caller cancellation.
3. **Reporting versus enforcement: Resolved.** The report identifies unused and
   incomplete recordings, but the core does not assign them a test outcome or
   call a test framework. Explicit, framework-independent evaluation helpers
   allow consumers to fail their own tests on selected conditions.
4. **Unattached tracks: Resolved.** Recorded system keys that were neither
   attached nor explicitly ignored appear in the report rather than being
   silently excluded. This diagnostic does not impose a test outcome.
5. **Unexpected operations: Resolved.** Every unexpected operation produces an
   immediate diagnostic that remains in the final report. Systems also
   propagate a distinct infrastructure error when their native API has a
   failure channel. A non-failable API requires an explicit deterministic
   continuation policy. None of these mechanisms calls a test framework or
   permits live fallback.
6. **Prompt test diagnostics: Resolved.** Setup can install a diagnostic sink
   that is notified after serious issues enter the ledger. Closure-backed and
   optional XCTest or Swift Testing integrations make failure reporting an easy
   consumer opt-in. A trap-based sink may exist for debugging but is not the
   recommended testing default. Notification does not replace a non-failable
   system's deterministic continuation policy.

These resolved points are the accepted answer to decision 5.

## Consistency review

The review after decision 5 found no conflict requiring an accepted decision to
be reopened.

- Decision 3's grouped lifecycle and cancellation boundary align with claiming
  a whole group once while reporting, but not enforcing, lifecycle completion.
- Decision 4's ordered tie-break now advances through atomically claimed
  candidates, and an exhausted candidate set is a distinct diagnostic.
- Earlier references to replay or selection failure describe infrastructure
  failure of an operation, not Diorama assigning a test outcome.
- Earlier references to verification describe structured reporting and
  consumer-invoked evaluation, not an implicit testing-framework assertion.
- Decision 3 narrowed decision 1's manual clock control to a future enhancement;
  real-time automatic logical time remains the only initial playback policy.

The mechanics that finalize a report, notify sinks of final diagnostics, and
clean up active claims remain intentionally deferred to decision 10.
