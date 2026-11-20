# 003-H12A — HTTP-owned incremental lifecycle capture

Complete. Initial local implementation completes on 2026-11-20 under the
owner-confirmed scope. On 2026-11-22 the owner approves the review updates,
squashing, and stacked PR creation. The review base is H12 at `6257ed0`.

## Adapter contract

The adapter embeds `HTTPRecordingCapture` in its Core-protected state. Begin
reserves a record and an invocation timestamp before conversion. An operation
handle carries its stable record identity. Each subsequent reservation ties
one observation to that handle, attempt number, position, and logical time.
Completions drain in reservation order. Diagnostics distinguish invalid
reservations, wrong attempts, and incompatible transitions. Freeze removes the
draft once and reports pending preparation or missing required completion.
These facts invalidate the candidate and include the record identity. A
preparation failure can retain its original stage without captured values.

The current phase owns its permitted transitions. A redirect or challenge retry
adds an enclosing edge and advances the attempt. Freeze folds these edges around
the active leaf. Body delivery preserves whole content or a prefix with its
observed segment weights and delays. Authored baseline values go through the
existing admission path. The new recording path selects body storage and proven
lengths automatically after preparation. Adapter authors can supply a final
interaction validator. See the [recording contract](../http-message-schema-v1.md#incremental-recording).

After redirect refusal, recording accepts an observed disposition under the
same head before body events begin. The refusal and the disposition answer
each start a local timing anchor. A pending disposition freezes as open.

## Verification

Eleven HTTP recording test functions pass, including seven invalidation cases
in one parameterized test. Tests drive public DioramaHTTP APIs inside Core system
executions. Only the Core clock injection uses testable access. A controlled
clock puts 2 seconds between redirect presentation and answer, and 50 ms between
answer and the next head. The recorded continuation delay is 50 ms, including
when request conversion completes after the later events are prepared. Gaps of
500, 600, 500, and 0 microseconds produce segment delays of 1, 0, 1, and 0
milliseconds on the rounded timeline.

Assertions cover overlapping operations, repeated redirects and authentication
challenges, inherited and modified requests, refusal, returned and failed bodies,
unanswered decisions, observed cancellation failures, and a cancel followed by
success. Freeze tests retain the exact open prefix and withhold publication when
conversion is incomplete. A finish/complete race accepts only the corresponding
committed result or an unhealthy recording. Failed secret preparation retains
safe evidence. Additional tests verify inline/resource placement, exact bytes,
literal and derived lengths, recursive effective-method changes, preservation of
loaded literals during replay, and the finalization behavior of escaped handles.

The canonical macOS `scripts/check` passes on Xcode 27.2 / Swift 6.4.2,
including formatting, lint, host tests, coverage-export fixtures, public compiler
probes, release builds, and Random and Date examples. Verification here uses
controlled observations. Native callback correlation belongs to the URLSession
integration units.
