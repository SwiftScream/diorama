# Grouped replay selection

One keyed system attachment owns each typed track. A system selects a complete
prepared group from its own track, and the lease claims that group atomically.
The group's phases, events, timing, and conclusion then belong to that one
operation. Selecting another group in the same track does not impose a global
call order across distinct inputs or attachments.

## System selector

`GroupedReplaySelector<Input, Value>` receives a stable live input and the
track's immutable prepared records. It returns one of:

- `.equivalent(ids)` for all groups equivalent to the input, including those
  already claimed. Diorama chooses the earliest available identity in recorded
  order, so repeated equivalent calls advance once each.
- `.noMatch` when no recorded input matches.
- `.ambiguous(ids)` when the system cannot distinguish several different
  behaviors. Diorama does not choose one silently.

`exactInput` compares an `Equatable` stable input projection. `sequential`
selects the next available group when the capability has no meaningful input
matcher. A system can supply its own deterministic selector for domain rules.
Each returned identity must occur exactly once in the selected track; empty,
duplicate, foreign-track, and unknown identities are invalid selector results.

Selectors are pure functions of stable input and prepared records. They must
not access a live dependency, mutate a snapshot, or depend on scheduling,
locale, time, or process state. The callbacks run outside the lease lock, so
they can inspect safe state without blocking other claims. The final
availability check and claim occur under one lock. A racing caller cannot
receive a group already claimed by another caller.

For an interaction whose stable input is a `String`:

```swift
typealias Call = InteractionRecording<String, String, String, String, String>

let selector = GroupedReplaySelector<String, Call>.exactInput(\.input)
let claim = try lease.claimGrouped(matching: preparedInput.value, using: selector)
let group = claim.record.value
// The owning capability delivers this group's behavior through its own API.
```

`preparedInput` must already have crossed the system's replay preparation
boundary. `claimGrouped` does not prepare native input or deliver events.
`InteractionRecording` and `SubscriptionRecording` declare their strict
recorded conclusion through `GroupedReplayRecording`. A custom grouped value
conforms to that protocol so an intentional open horizon is never mistaken for
an incomplete terminal replay.

## Failure and safe context

Selection failures are distinct: no match, matching records exhausted,
ambiguous candidates, and invalid selector output. Closed or wrong-mode use
retains its separate lease diagnostic. Every failure is reported before a
`SequentialOperationFailure` is thrown. The report contains the selected
attachment and track, safe record identities for exhaustion or ambiguity,
and the selector's setup-authored rule label. A selector may also supply
semantic difference field labels, such as `input`, without including values,
native objects, or secrets. Replay does not contact a live dependency after
any selection failure.

## Use and progress

A successful claim makes the entire group used immediately. Abandoning or
canceling the operation, or failing a later continuation, never returns it to
availability. The claim's `advance(to:)` records a monotonic count of internal
steps reached. `complete()` marks a terminal recorded conclusion reached;
an explicitly open group has no terminal conclusion to mark. Progress does
not change the used count, and progress after lease closure cannot change a
frozen report.

At `finish()`, each replay track reports its exact unused identities, even when
claims leave holes in recorded order. `selectedGroups` reports claim progress
and whether each conclusion is pending, completed, or open by design.
`allRecordingsUsed` evaluates consumption. The separate opt-in
`allSelectedRecordingsCompleted` condition identifies pending terminal claims;
open groups are satisfied by design. Both conditions can be evaluated for the
whole scenario or selected attachment keys. Neither assigns a test outcome or
calls a testing framework.

This unit provides selection and claims only. Stream publication and
interaction continuation delivery use later capability-specific services.
