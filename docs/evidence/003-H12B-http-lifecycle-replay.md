# 003-H12B — HTTP-owned lifecycle replay

The owner confirms this unit on 2026-11-20 and approves the timing and
scheduling-failure review updates, squashing, and stacked PR creation. The
stacked review base is the H12A capture commit `17ecea4`. The
[adapter contract](../http-message-schema-v1.md#replaying-an-http-interaction)
describes setup, delivery, and shutdown.

## Delivery and ownership

The replay controller captures the initial timing anchor and claims one
interaction under Core state protection. It compares prepared initial requests
and redirect answers through the same setup-owned matcher. The controller
schedules one event at a time through the attachment lease. Response heads carry
the effective recorded request from the selected edge. Body slices share their
source bytes and follow the edited profile's allocation. Each successful handoff
advances the claim. A returned or failed conclusion releases the operation. An
open horizon acknowledges consumption and retains the pending operation until
cancellation or shutdown.

Each presented decision has a single-use answer bound to the record and
presentation. Presentation can return before the consumer answers. Submitting
a compatible prepared answer captures a fresh anchor. Its continuation starts
only after handoff of the presentation returns. Other delays retain their
cumulative deadlines from the current anchor. Replay reports an incompatible
choice or an answer beyond the horizon through a safe record diagnostic and
an error to the answering adapter.

Adapter setup calls `close()` from its stop hook. Closing drops the matcher,
execution services, and pending operations. A scheduling scope already in a
delivery hook remains joined until that hook returns. An escaped answer holds
weak references to the controller and time service.

## Timing API review

The owner confirms keeping timing capture inside the replay API. The planned
URLSession adapter resolves task ownership asynchronously to find the execution
and its clock. Request and answer preparation are synchronous. The answer
callback captures time before entering the replay actor.

Native conformance should verify first-delivery timing from the replay start
boundary and continuation timing from the current answer. Revisit explicit
timing captures if latency before either replay entry point shifts a deadline
that the adapter needs to preserve. See [I01 for request routing](../plans/003-clean-slate-implementation.md#003-i01--instrumented-session-and-bodyless-get-vertical-path)
and [I04–I07 for native decision delivery](../plans/003-clean-slate-implementation.md#003-i04--segmented-delegate-delivery-and-response-disposition).

## Local verification

The HTTP replay suite drives public DioramaHTTP entry points using Core system
definitions, a controlled execution clock, and awaited delivery hooks. Tests
exercise the following behaviors:

- Credential retry, followed and modified redirects, refused redirects, safe
  stale-answer rejection, and inherited or changed effective request context.
- At a challenge presented at 100 ms, answers at 200 ms and 2 s put the next
  head at 250 ms and 2.05 s respectively. An extra 15 ms inside the presentation
  hook leaves the deadline intact. Zero-delay answers preserve causal order.
- After redirect refusal, replay presents the disposition under the original
  head. A controlled clock verifies timing from each current answer.
- Successful body and trailer delivery, cancellation failures, pre-head failure,
  open and failed body prefixes, allocated resource bytes with edited weights
  and delays, and pending response dispositions.
- Exclusive FIFO claims after a mismatch, safe beyond-horizon evidence, progress
  after cancellation or replay shutdown during a handoff, frozen usage after
  finish, and release of open operations on both cancellation and finalization.
- A rejected follow-up registration produces one terminal infrastructure event
  and one record-scoped diagnostic. Progress retains the preceding response
  handoff and the claim remains unconsumed.

All ten focused test functions pass with warnings treated as errors. The
canonical macOS `scripts/check` passes on Xcode 27.2 and Swift 6.4.2 with zero
format and lint violations, 823 tests across nine host products, coverage-export
fixtures, compiler probes, release builds, and the Random and Date examples.

The verification boundary is the shared HTTP controller. H13 owns whole-record
registration and capability validation. Native URLSession presentation remains
assigned to the adapter units.
