# In-flight diagnostic inspection and test integration

- Status: Deferred design considerations; no API or implementation approved.
- Recorded: 2026-10-12, during 003-Fa09.
- Revisit: Together with the common test-integration policy before 003-J01/J02,
  as a separately scoped, owner-approved work item if inspection is wanted.
- Accepted baseline: [Final-report-only diagnostics](design-decisions/05-consumption-and-verification.md#final-report-only-diagnostics--owner-approved-2026-10-12).

## What could “healthy” mean?

There is no single diagnostic severity ladder or Core test-pass status. The
current facts and explicit final-result evaluators distinguish:

| Possible check | Meaning and limits |
| --- | --- |
| No diagnostics | Strictest diagnostic check: even informational baseline facts count. It says nothing about unclaimed replay records or later cleanup/publication. |
| Healthy recording | No retained diagnostic invalidates the candidate. Replay exhaustion, cleanup failure, and other test-relevant facts need not invalidate a recording. |
| No unexpected operations | A chosen set of Core operation failures. System-defined labels need system-specific policy; native recorded domain errors are not automatically infrastructure failures. |
| Usage/lifecycle requirements | Unclaimed records and unfinished claims can be normal while work is running. Final-result evaluations cannot simply be applied mid-execution without defining the boundary. |
| Cleanup/publication success | Known only when those stages run. A healthy recording can still fail publication. |

An empty ledger does not guarantee successful future work. A check reports
facts retained by its observation boundary, not pending operations or a promise
that no new diagnostic can arrive. Already failed facts remain failed for that
execution; later checks cannot repair them by consuming observations.

## Workable future choices

| Option | Value | Cost and unresolved contract |
| --- | --- | --- |
| Keep final reports only | Smallest API; test integrations evaluate a complete outcome during their valid context. | No diagnostic-driven early exit; native thrown errors remain available. |
| Simple check methods | Illustrative `context.hasNoDiagnostics()` or an explicitly named recording-health check supports caller-selected early return/throw. | Define which facts, snapshot atomicity, and behavior before startup/after finish. Boolean answers provide little explanation; several separate calls can observe different boundaries. |
| One checkpoint snapshot | Return health plus the diagnostics retained so far from one atomic boundary. The immutable snapshot is non-consuming. | Copy/sort cost; define what is included, identity/lifetime, and whether this merely observes or also waits for work. Prefer observation without a drain unless a real integration requires more. |
| Snapshot plus cursor | A caller can ask for facts since its previous observation, useful for incremental test issue reporting. | Specify per-execution cursor identity, invalid/foreign cursors, concurrent readers, ordering, and integration deduplication. More API and proof than a Boolean. |

A non-consuming snapshot or caller-owned cursor can reuse the existing ledger
lock without invoking consumer code under it. It need not introduce a global
consumption pointer, callback reentry, or a delivery queue. Nevertheless its
public concurrency semantics need explicit design and tests. Two callers should
be able to inspect independently; inspection must not remove diagnostics from
the final report or from another reader.

The cursor should track an admission watermark, not an index into the sorted
report: a later diagnostic can sort before an earlier entry because reports use
attachment/track/record ordering. Select the included facts and next watermark
atomically so a concurrent writer is neither missed nor duplicated. Decide
whether cursors are scoped to pre-finish facts only or support a separate
post-finish log; never silently mix a completed report with later misuse.
Sequential reuse of one `Diorama` still creates distinct executions, so a cursor
from an earlier run must not accidentally select facts from the next run.

A checkpoint does not by default wait for all earlier application work to
finish. Callers establish their own meaningful operation boundary. Waiting or
flushing would add work ownership, cancellation, deadlock, and ordering questions
that a simple observation need not have. These diagnostic checkpoints are
separate from [named replay-progress checkpoints](checkpoint-design-notes.md),
which may compare persisted system progress and require schema decisions.

## Test integration and early abandonment

Design XCTest and Swift Testing helpers from completed reports first. Evaluate
while the test context is valid, including when the body throws: finalize and
publish according to existing policy, inspect `Diorama.report`, then preserve
the original body error for the framework. Do not replace that error with a
report wrapper. Startup failures carry separate completed evidence; late facts
cannot retroactively fail an ended test.

If intermediate inspection is later selected, decide which conditions an
integration checks, where the caller requests it, and whether to record a test
issue, return, or throw. These are opt-in consumer policies. Early return/throw
must still execute the normal finish and optional publication path; it does not
undo a healthy recording or silently cancel consumer-owned passthrough work.
Application child tasks and native live resources retain their existing owners.

A checkpoint/cursor integration must avoid reporting the same fact again during
final evaluation while still examining new cleanup/publication failures and
final usage requirements. Define cursor advancement on issue-reporting failure
and test-context expiry. A cursor can support this policy but does not itself
guarantee exactly-once test-framework delivery.

Before implementation, compare the smallest useful checks against concrete
XCTest/Swift Testing examples, including thrown bodies, asynchronous child work,
nonthrowing continuation after replay exhaustion, concurrent reporters, and
post-finish misuse. None of these notes adds a context method, cursor type,
stream, live sink, test dependency, or automatic abort policy in Fa09.
