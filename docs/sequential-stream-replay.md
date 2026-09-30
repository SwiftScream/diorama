# Sequential stream replay

`replaySubscription` combines a `GroupedReplaySelector`, a prepared
`SubscriptionRecording`, the execution time service, and the attachment's
`SchedulingLease`. A system supplies stable subscription input and an async
delivery closure that presents the replayed behavior through its own API.

```swift
let subscription = try subscriptionTrack.replaySubscription(
    matching: stableConfiguration,
    using: selector,
    time: context.time,
    scheduling: context.scheduling
) { event in
    await adapter.present(event)
}
```

The selector claims one complete group before any delivery. Each subscription
captures its own logical-time anchor at start. Values and nonterminal dependency
failures are due at their recorded offsets from that anchor. A timed normal or
failed conclusion follows its own offset. When a normal conclusion has no
meaningful time, it follows the final event at that event's offset, or the
subscription start for an empty group. An open group delivers its recorded
events and never invents a completion.

One subscription registers its next event only after the async delivery of its
current event returns. This preserves its semantic order even when offsets are
equal and the scheduler submits other subscriptions concurrently. The delivery
closure must await the adapter work that constitutes delivery. The helper does
not order independent application tasks or events across subscriptions.

`cancel()` prevents future events and is idempotent. A callback already running
may finish. The whole group remains used; its progress counts events whose
delivery returned, and a terminal conclusion is marked complete only after its
delivery returned. Caller cancellation is runtime control, not a persisted
event. During execution finalization, pending registrations are canceled and
claimed delivery is joined before usage freezes. An expected attempt to queue
the next event after finalization closes admission ends the subscription
without an unexpected-operation diagnostic.
The active delivery closure owns the remaining replay payload; an escaped
subscription handle does not retain that payload after pending work is canceled
or the last delivery finishes.

The helper supplies delivery mechanics only. A first-party location system or
consumer adapter chooses its own selector, native presentation and
cancellation policy, and cleanup ownership.
