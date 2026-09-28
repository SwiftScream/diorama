# Grouped lifecycle recording

An interaction or subscription occupies one typed sequential record. Its
accumulator accepts observations during a recording execution. At `finish()`,
Diorama freezes it into one immutable group and validates the complete recording
before the candidate can be returned or published.

## Interaction

Use a `SequentialTrackLease<InteractionRecording<Input, Observation, Decision,
Output, Failure>>` for correlated one-shot operations. Capture logical time at
the operation boundary, then begin the group:

```swift
typealias Call = InteractionRecording<String, String, String, String, String>

let beganAt = try time.capture()
let call = try lease.beginInteraction(at: beganAt, preparation: ValuePreparation<Call>()) {
    try ValuePreparation<String>().prepare(
        capturing: { "request" }, purpose: .recording, reporter: reporter)
}

let observedAt = try time.capture()
let phase = try call.observe(at: observedAt) {
    try ValuePreparation<String>().prepare(
        capturing: { "challenge" }, purpose: .recording, reporter: reporter)
}

let decidedAt = try time.capture()
try call.respond(to: phase, at: decidedAt) {
    try ValuePreparation<String>().prepare(
        capturing: { "continue" }, purpose: .recording, reporter: reporter)
}
```

`returned(at:capturing:)` and `failed(at:capturing:)` are alternative terminal
operations. If neither occurs before the recording horizon, the immutable
conclusion is `openAtRecordingHorizon`. This describes observation ending while
the operation remains active; it does not invent a terminal event. A phase
handle belongs to one interaction, and each phase can receive at most one
decision. The enclosing track record provides stable group correlation.

## Subscription

Use `SequentialTrackLease<SubscriptionRecording<Input, Value, Failure>>` for a
repeated or unsolicited callback source. `beginSubscription(at:preparation:
capturing:)` reserves its record position. `deliver(at:capturing:)` appends a
value; `reportNonterminalFailure(at:capturing:)` records an error after which
delivery may continue. `finish(at:)` and `fail(at:capturing:)` are alternative
terminal operations. `finish()` without a capture stores no completion offset
when that timing is not meaningful for the system. An active subscription
freezes as `openAtRecordingHorizon`.

Caller cancellation controls a live or replay operation. It is not a recorded
event by default. A dependency-emitted cancellation failure can be a typed
terminal failure when the owning system defines it as observable behavior.

## Preparation, time, and order

Every input, phase, decision, output, emission, and failure closure returns a
`PreparedValue` produced by the system's `ValuePreparation` at the observation
boundary. Native values remain in the adapter's capture closure. Call
`ExecutionTime.capture()` before conversion, then pass that capture to the
accumulator; offsets are nonnegative logical durations from the group start.
Do not persist host instants or add timestamps to unrelated sequential tracks.

The lease reserves each group's track position before calling its input closure.
An accumulator reserves each phase, decision, emission, or conclusion before
calling its field closure. Slow conversion therefore cannot reorder already
reserved observations. Different groups may overlap, but each group's phases
and conclusion remain correlated with its own record. Equal offsets preserve
the reservation order within the group.

The group policy supplied at begin performs validation of the complete group
at the recording horizon. Its capture transforms are not run again: nested
fields were already prepared when observed. Use the same immutable validation
rule when admitting a programmatic or decoded baseline through
`SystemPreparationContext.lease(for:preparation:)`. Immutable constructors
reject negative or conflicting timing, and their conclusion enums require one
explicit returned, failed, finished, or open interpretation.

## Finalization and failure

`finish()` closes admission, joins Diorama-owned scheduled delivery, and freezes
each reserved group before constructing the candidate. A group with unfinished
conversion or failed complete validation makes the whole recording candidate
unhealthy. Failed capture and invalid transition diagnostics contain stable
record identity and a safe issue category, never captured values or native
errors. A duplicate conclusion or observation after a terminal conclusion is
rejected. Calls after the recording horizon cannot change the frozen result;
their diagnostics enter the reporter's separate post-finish log.

The models are in-memory semantic values and have no `Codable` schema in this
unit. Later selection and delivery services consume the strict groups; this
unit does not define replay matching or schedule their events.
