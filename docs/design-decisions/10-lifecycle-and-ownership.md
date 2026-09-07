# Decision 10: Lifecycle and ownership

- Status: Accepted
- Last updated: 2026-09-06
- Depends on: [Decision 1: Common abstraction](01-common-abstraction.md),
  [Decision 2: Shared and system-specific semantics](02-shared-vs-system-semantics.md),
  [Decision 3: Recorded behaviors](03-recorded-behaviors.md),
  [Decision 5: Consumption and verification](05-consumption-and-verification.md),
  [Decision 6: Runtime-to-snapshot conversion](06-runtime-to-snapshot-conversion.md),
  [Decision 7: Persistence boundary](07-persistence-boundary.md),
  [Decision 9: Normalization and redaction](09-normalization-and-redaction.md)

## Decision

What lifecycle owns scenario loading, system activation, recording, replay
state, the recording horizon, verification, publication, and cleanup?

## Context

Diorama is intended to need little or no interaction from the body of a useful
test. Setup connects dependencies to a configured scenario; application code
then uses those dependencies normally. The lifecycle still needs an explicit
boundary around that period so Diorama can:

- load and validate a complete heterogeneous scenario before replay begins;
- install adapters only after their configuration is usable;
- isolate replay claims and diagnostics to one test run;
- decide when a recording has reached its horizon;
- turn unfinished operations into valid open recordings;
- produce verification and publication reports;
- publish one complete healthy candidate;
- remove interception state and release adapter-owned resources.

Relying on object destruction is insufficient. Swift destruction cannot await
publication or adapter shutdown, cannot return a report, and may be delayed by
retention cycles. Conversely, requiring application-facing test code to call
Diorama after every operation would undermine the setup-oriented design.

## Terms

### Scenario definition

A **scenario definition** is reusable, immutable configuration. It includes:

- scenario identity and optional repository destination;
- scenario mode and attachment-specific mode overrides;
- ordered system attachment declarations and persistence registrations;
- matching, transformation, timing, and continuation policies;
- intentionally ignored persisted attachment keys;
- diagnostic sinks and other execution policy.

A definition owns no claims, native adapter registrations, working recording,
or open resource handles. It can be reused to create independent executions.

### Scenario execution

A **scenario execution** is the single owner of mutable state for one bounded
run. It owns:

- the loaded immutable baseline, when one exists;
- the working candidate and capability accumulators;
- attachment instances and adapter leases;
- replay claims, lifecycle progress, and logical-time scheduling;
- the diagnostic ledger and recording health;
- staged resources and a single finalization result.

An execution is concurrency-safe for operations within its run, but is not a
container for sharing consumption state between otherwise independent tests.
Starting the same definition twice creates two independent executions.

### Adapter lease

Activation of a concrete integration produces an execution-owned **adapter
lease**. The lease represents interception registrations, wrappers, observation
hooks, scheduled replay work, and other resources that must be deactivated. It
does not imply ownership of a consumer-supplied live dependency. A live native
operation may own a minimal forwarding continuation after it starts; at the
recording horizon that continuation must detach from the execution and its
recording state rather than being cancelled merely to release the lease.

### Recording horizon

The **recording horizon** is the logical-time boundary after which native
observations no longer contribute to the candidate. A grouped lifecycle without
a conclusion at that boundary becomes `openAtRecordingHorizon`, as accepted in
decision 3.

## Lifecycle states

The conceptual execution state machine is:

```text
configured
    -> starting
        -> running
        -> startFailed
    -> finishing
        -> finished
```

`configured` belongs to the definition or builder rather than an active
execution. A start failure rolls back everything activated during that start
attempt and returns no running execution. Once finishing begins, the execution
cannot return to running. Concurrent finish requests observe the same eventual
immutable result.

An explicit abort path may share the `finishing -> finished` cleanup machinery
while refusing publication. It is not a shortcut that skips adapter shutdown
or staged-resource cleanup.

## Proposed startup sequence

System declarations must be available before decoding because persistence uses
registered system identities and `Codable` stable types. Runtime interception
must not be active while the baseline is only partially loaded. Startup should
therefore proceed in phases:

1. Freeze and validate the scenario definition, including unique attachment
   keys, effective modes, system versions, and persistence registrations.
2. Load the optional baseline and retain the distinct load outcome defined by
   decision 7.
3. Decode, migrate where allowed, normalize, and validate the baseline using
   the declared systems and current setup policy.
4. Enforce setup-wide requirements, including the rule that any replay
   attachment requires a usable baseline.
5. Construct execution services: logical time, track access, claim state,
   diagnostic ledger, candidate accumulators, and resource staging.
6. Prepare each system attachment without exposing it to application calls.
7. Activate concrete adapters in deterministic attachment order and retain
   their leases.
8. Publish the execution to the caller only after every required attachment is
   active.

Preparation and activation are separate concepts even if a simple system
implements them in one internal operation. If any phase fails, startup records
a structured diagnostic, deactivates already activated leases in reverse order,
cleans temporary resources, and returns a structured startup failure. No
partially active execution escapes.

Passthrough attachments still participate in lifecycle and cleanup when they
install a wrapper or interception mechanism. They do not read or mutate scenario
tracks.

## Running ownership

While running, all scenario mutation and replay state belongs to the execution:

- systems submit prepared stable observations through execution services;
- interaction, stream, and clock capabilities own their typed accumulators;
- the core serializes track mutation and atomic replay claims;
- logical-time scheduling cannot outlive the execution;
- diagnostics enter the execution ledger before a sink is notified;
- raw native values and adapter tasks remain owned by the concrete system.

An adapter must not retain the execution indefinitely through an accidental
strong-reference cycle. The concrete implementation can use weak routing or an
explicit lease topology, but cleanup correctness cannot depend on a weak
reference disappearing.

## Proposed finalization sequence

Finalization should be explicit, asynchronous, idempotent, and concurrency-safe.
The first call starts one internally owned finalization operation; all later
calls await and return the same result.

The conceptual sequence is:

1. Atomically transition from running to finishing and stamp the recording
   horizon in shared logical time.
2. Close admission of new application operations to the execution.
3. Ask every system to quiesce Diorama-owned delivery and observation at that
   horizon, then deactivate adapter leases in reverse activation order.
4. Freeze capability accumulators, giving every open recording the explicit
   `openAtRecordingHorizon` conclusion.
5. Collect system verification contributions. Diagnostic collection remains
   open through the remaining finalization stages, until the result is frozen.
6. For recording tracks, associate baseline groups, preserve authored
   overrides, construct the complete candidate, and validate its health.
7. If publication was requested and the candidate is healthy, encode, stage,
   and atomically publish the complete logical scenario. This is the only
   initial durable write boundary; there is no incremental public `flush()`
   during execution.
8. Clean unpublished staging and all remaining execution-owned resources.
9. Freeze and return one structured finalization result containing verification,
   recording, publication, and cleanup information.

Diagnostic sinks remain active through finalization so encoding, publication,
and cleanup problems can be reported promptly. The immutable result is the
authoritative aggregate through its freeze boundary; the owner-approved
post-finish clarification below governs diagnostics produced later.

Finalization must not wait indefinitely for a consumer-owned native operation
to conclude: an interaction that remains open is a representable recording, not
a reason to hang teardown. Nor should Diorama cancel a consumer-owned live
operation merely because recording ended. The adapter must stop observing that
operation at the horizon without changing its live behavior.

Replay work differs because Diorama owns its scheduled delivery. Finalization
stops future Diorama-owned callbacks and records the selected lifecycle's final
progress in the report. No replay callback may escape after the adapter reports
that it is quiescent.

## Finalization result

Startup may fail before a running execution exists, so it should throw or
return a structured startup failure that includes safe diagnostics and confirms
rollback disposition.

Once an execution is running, ordinary runtime problems are already represented
in its ledger and health. `finish()` should return a structured result rather
than throw away that aggregate in favor of the first finalization error. Its
shape conceptually includes:

```text
ScenarioFinalizationResult
    verification report
    recording and candidate-health report
    publication disposition
    cleanup disposition
```

The result itself has no test-framework pass/fail status. Decision 5's explicit
evaluation helpers and optional test integrations interpret it. The API should
make accidental result dismissal visible through normal Swift unused-result
diagnostics rather than marking it `@discardableResult`.

A caller task being cancelled while awaiting finalization must not abandon a
half-cleaned adapter or half-staged publication. Once started, the execution
owns the finalization operation to completion. Cancellation can stop the caller
waiting, but a later call can await the same result.

### Post-finish reporting lifetime — 2026-09-06

The owner approved this clarification while resolving
[Plan 003, Q3](../plans/003-clean-slate-implementation.md#q3--diagnostics-after-an-immutable-final-result-resolved-by-owner-2026-09-06).
[Decision 5](05-consumption-and-verification.md#post-finish-diagnostic-retention--2026-09-06)
defines the immutable report boundary and separately inspectable post-finish
diagnostic log.

An escaped dependency may retain the small diagnostic reporter and the frozen
state required for its specified post-finish behavior. Diorama must not keep
sessions, live sources, scheduling machinery, or recordings alive merely to
report later misuse. Consumers may also retain the reporter directly for
inspection without retaining the execution. Its lifetime ends when its
remaining owners release it; no global registry keeps it alive.

Finalization still closes admission, quiesces owned delivery, and releases
execution-owned resources. New misuse of an escaped dependency records a safe
diagnostic and notifies the configured sink without restarting the execution,
mutating the frozen result, or scheduling replay callbacks. This notification
is a response to a new call, not delayed delivery from the finished execution;
the quiescence guarantees in this decision and Decision 14 apply to the latter.
It does not permit a stopped adapter's late native callbacks to resume
observation or replay delivery.

The reporter does not keep a test context valid. Opt-in testing integrations
must honor that context's lifetime even when the reporter and escaped handles
outlive it. Exact synchronization and ownership types remain reviewable
implementation choices; the retained log must remain observable without
keeping the completed execution's machinery alive.

## Ergonomic lifecycle APIs

The authoritative primitive is an explicitly retained execution with an
asynchronous, idempotent `finish()`. This fits XCTest-style setup and teardown,
integration harnesses, and applications whose instrumented dependency must
cross helper boundaries.

A scoped asynchronous helper should wrap the common case:

```swift
let result = try await Diorama.withExecution(definition) { execution in
    let client = try execution.dependency(for: "api", as: HTTPClient.self)
    return try await exerciseApplication(using: client)
}
```

This is illustrative rather than a final API. The helper must always run
finalization after its body returns, throws, or is cancelled. It should expose
the body outcome and finalization result without letting one silently mask the
other.

Optional XCTest and Swift Testing integrations can connect this primitive to
their supported per-test lifecycle hooks. Such integrations may reduce a test
body's Diorama interaction to obtaining already configured dependencies, but
the core must not infer a test boundary or depend on either framework.

`deinit` is only a misuse backstop. It may synchronously detach a simple routing
token or emit a best-effort warning where safe, but it cannot finalize a
recording, publish a scenario, guarantee asynchronous cleanup, or manufacture a
verification result.

## Ownership rules for integrations

Each concrete system must declare and honor ownership explicitly:

- A consumer-supplied live dependency remains consumer-owned. Finalization does
  not close, invalidate, or cancel it unless the setup API explicitly transfers
  ownership.
- A wrapper, proxy, routing registration, delegate bridge, replay task, or
  scheduler created by Diorama is owned by its adapter lease.
- A returned instrumented dependency must not remain usable as if replay or
  recording were active after its lease is deactivated. Its system defines a
  deterministic post-finish behavior and diagnostic where the native API can
  still be called.
- Temporary files and unpublished resources are execution-owned. Published
  resources become repository-owned only as part of the atomic commit.
- Test-framework objects and source locations belong to their optional
  integration, not to the core execution.

System cleanup failures enter the final result and do not prevent best-effort
cleanup of later leases. A failure to establish a reliable horizon or freeze
the candidate makes recording unhealthy and prevents publication. A cleanup
failure discovered after a valid atomic publication is reported but cannot
retroactively undo that publication. Reverse activation order gives nested
integrations a predictable unwinding order; reports retain deterministic
attachment order rather than incidental task completion order.

## Body failure and publication

The core `finish()` operation does not know whether the surrounding test passed
or failed. If explicitly called, it applies the definition's requested
publication policy to any healthy candidate.

A scoped helper does know whether its body returned or threw. The recommended
default is:

- finalize and allow requested publication after a successful body;
- finalize but suppress publication after a thrown or cancelled body;
- preserve the body error and return or attach the complete finalization result.

This avoids replacing a useful baseline with behavior captured during an
aborted test run. A deliberate option can allow publication after body failure
for diagnostic or fixture-generation workflows. Merely recording a test issue
through a diagnostic sink is not equivalent to the body throwing, so publication
health continues to follow Diorama's structured candidate-health rules.

## Worked examples

### XCTest-style HTTP replay

Test setup starts one execution and receives its instrumented HTTP client. The
application uses that client without Diorama-specific operation identifiers.
Teardown awaits `finish()`, evaluates unexpected-operation policy if desired,
and retains the report. The consumer-supplied passthrough client is not
invalidated; the Diorama wrapper and interception registration are removed.

### Recording an unfinished authentication exchange

An HTTP request receives an authentication challenge that application code
never answers. Finalization stamps the horizon and stops observation without
cancelling the live task. The interaction freezes with its recorded phases and
an `openAtRecordingHorizon` conclusion. A healthy scenario can publish that
valid open interaction.

### Location replay ending early

A replayed location subscription is selected and emits two of five recorded
updates before the test ends. Finalization cancels Diorama's remaining scheduled
deliveries, deactivates the delegate bridge, and reports the claim as used but
incomplete. It does not fail the test or interpret the application's stop
behavior as an error.

### Two independent clocks

One definition attaches `device-clock` and `server-clock`. Each execution gets
fresh sequential cursors and logical-time scheduling for both attachments.
Finishing one execution stops only its scheduled sleepers; another execution
created from the same definition remains independent.

### Startup failure after partial activation

The second of three system adapters fails to activate. Startup deactivates the
first adapter, cleans staging, and returns a structured failure. The third is
never activated and no runnable execution or partially instrumented dependency
is returned.

## Recommendation

Separate reusable immutable scenario definitions from single-run scenario
executions. Make one execution the sole owner of the baseline, candidate,
claims, logical time, diagnostics, adapter leases, staging, finalization, and
cleanup for that run.

Start in ordered phases: validate configuration, load and validate the complete
baseline, construct services, then activate systems. Roll back partial startup.
Finish explicitly and asynchronously through one idempotent operation that
stamps the recording horizon, quiesces adapters, freezes groups, verifies,
publishes a healthy candidate when allowed, cleans resources, and returns one
structured result.

Provide scoped and test-framework conveniences over the explicit primitive.
Never rely on destruction for publication or correctness. Do not cancel or
close consumer-owned dependencies during cleanup, and do not allow
Diorama-owned replay delivery to outlive a finished execution.

## Consequences

Benefits:

- Every mutable operation has one clear per-run owner.
- Independent tests cannot accidentally share replay consumption state.
- Replay starts only after a complete baseline and all required systems are
  usable.
- Open recordings reach a deterministic horizon without hanging teardown.
- Partial startup and finalization failures have explicit rollback and reports.
- Scoped helpers can keep ordinary test bodies largely unaware of Diorama.

Costs:

- Correct use requires an asynchronous finalization boundary somewhere in the
  harness.
- Adapters need real activation, quiescence, and deactivation behavior.
- A final result can still be ignored despite compiler warnings.
- Suppressing publication after a scoped body failure requires the helper to
  preserve two outcomes coherently.
- Consumer code that lets an execution escape without finishing cannot be made
  fully correct by `deinit`.

## Explicit non-decisions

This proposal does not determine:

- concrete builders, generic types, or dependency lookup syntax;
- exact XCTest or Swift Testing lifecycle integration APIs;
- final diagnostic, report, and evaluation type names;
- synchronization implementation inside an execution;
- system-specific behavior when an instrumented dependency is called after
  finalization;
- deadlines for buggy adapters that fail to quiesce;
- whether a future long-running process can rotate through several recording
  horizons;
- HTTP adapter ownership details governed by decisions 11 and 12.

## Review questions

1. **Execution unit: Resolved.** A reusable immutable definition creates a
   fresh, independently consumed execution for each test or deliberately
   bounded run. That execution is the sole owner of its mutable scenario state;
   otherwise independent tests do not share an execution.
2. **Startup boundary: Resolved.** Attachment declarations and persistence
   registrations are frozen before loading. Adapters activate only after the
   complete baseline is usable for the configured execution. A partial
   activation failure rolls back already activated adapters and returns no
   runnable execution.
3. **Finalization API: Resolved.** Explicit asynchronous idempotent `finish()`
   is the authoritative primitive. Scoped helpers and optional test-framework
   integrations can invoke it automatically, but `deinit` cannot replace it or
   provide correctness. Concurrent finish calls await the same final result.
4. **Recording horizon: Resolved.** Finalization establishes an immediate,
   atomic logical-time horizon. It stops scenario observation and future replay
   delivery, explicitly concludes unfinished recordings at the horizon, and
   does not wait for or cancel consumer-owned native operations. A later native
   event may still be forwarded where required by the adapter, but cannot
   mutate the finished scenario.
5. **Body failure: Resolved.** A scoped helper completes finalization but
   suppresses publication by default when its body throws or is cancelled. It
   preserves the body failure, exposes the finalization report, and leaves the
   previous published scenario intact. An explicit fixture-generation policy
   may publish a healthy candidate despite body failure. Explicitly managed
   executions follow their configured publication policy because `finish()`
   cannot infer the surrounding test outcome.

These resolved points constitute the accepted answer to decision 10.

## Consistency review

The review after resolving decision 10 found no conflict requiring an accepted
decision to be reopened.

- The fresh per-run execution is the owner of consumption state already scoped
  to one execution by decision 5.
- The immediate recording horizon gives decision 3's
  `openAtRecordingHorizon` conclusion and decision 7's candidate finalization a
  single explicit owner.
- The finalization result combines decision 5's verification report with
  decision 7's recording and publication report without assigning a test
  outcome in the core.
- Publishing only from finalization completes decision 7's whole-candidate
  transaction and removes the need for a public incremental `flush()`.
- Loading before activation respects decisions 7 and 8: registered system types
  are available for decoding, and unusable replay input fails before an adapter
  can intercept an operation.
- Adapter leases implement decision 2's cleanup responsibility while retaining
  decision 6's boundary: native forwarding tails cannot retain or mutate stable
  scenario state after the horizon.
- Structured startup and finalization diagnostics remain subject to decision
  9's preparation and safe-rendering boundary and decision 5's framework-neutral
  reporting rules.
- Suppressing scoped publication after body failure is compatible with decision
  7's atomic replacement rule; it selects `not requested` for that run and
  preserves the previous publication.
