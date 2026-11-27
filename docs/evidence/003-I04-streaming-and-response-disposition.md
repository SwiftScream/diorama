# 003-I04 — Streaming and native response decisions

## What the application observes

Foundation can buffer a short text response until the URL protocol supplies
both its bytes and end-of-input. A delegate data task can then receive a real
response decision while a completion handler, async data call or async byte
sequence can finish with the same response without receiving that question.
The session delegate and task flags at creation do not reliably distinguish
these paths. The adapter follows the
[application-visible timing and verification contract](../design-decisions/12-urlsession-scope.md#application-visible-response-decisions--2026-11-26-amended-2026-11-27).

During recording the private session forwards the head and each segment as
they arrive. For a task with a suitable delegate, the recorder preserves the
prepared head. If Foundation presents a decision, capture continues from that
head using the application's answer, segment callbacks and task completion.
This discards any private bytes or EOF that Foundation buffered before asking.
If the question never occurs, the ordinary transport observations retain their
original times, including any prefix available at scenario finish.

| Live observation | Recording and replay |
| --- | --- |
| Delegate allows | Deliver the recorded segments and terminal outcome at their delays from the current allow. |
| Delegate cancels | Store the resulting dependency failure and replay it once. |
| Delegate still holds its answer at finish | Freeze the decision open. The live task can still finish. Replay satisfies the recording when the question reaches the delegate. |
| Caller uses a completion handler or async API and Foundation skips the question | Store an ordinary body. Compatible calls can replay it across API forms. |
| Replay cannot present a required question | Reject a known incompatibility before the response. Otherwise task completion or scenario finish reports `urlsession.response-decision-not-presented` once and leaves the claim unconsumed. The app may already have seen a successful HTTP response. |
| Consumer requests download or stream conversion | Diagnose the unsupported transition and reject the recording. |

The adapter accepts supported data delegates visible at task creation, including
a configured session delegate. A supplied delegate queue must be serial.
Replacing the task delegate after creation displaces the adapter and the task
is rejected before matching or forwarding.

## Production conformance tests

The [native decision tests](../../Tests/DioramaURLSessionTests/SessionReplayDecisionTests.swift)
send a short text response from a loopback HTTP origin through the public
recording API. They decode the resulting interaction and replay it with a
fresh delegate. The allow, cancel, and unanswered cases compare the native
response and visible body or failure. Only the recording connects to the
origin. The open case also answers after recording finishes and verifies that
the original live task receives its body. A second test captures a 1,024-byte
prefix followed by a delayed five-byte tail. Replay preserves both segments
and their timing after a deliberately held answer.

The same suite covers explicit task cancellation, unsupported transitions,
overlapping identical requests, partial and failed bodies, and missing
callbacks at native completion or scenario finish. Aggregate calls with an
installed response delegate produce ordinary recordings. A hand-authored
fixture independently checks decision-relative segment and completion delays.

The [streaming and API tests](../../Tests/DioramaURLSessionTests/SessionBridgeTests.swift)
hold back the origin's tail until the caller has received the head and read
the prefix through `bytes(from:)`. They also exercise all 25 pairs of supported
aggregate recording and replay APIs with zero additional origin requests.

## Verification

On Xcode 27.2 and Swift 6.4.2, the macOS gate passed 900 tests, strict lint,
compiler probes, release builds and the examples. The iPhone 17 Simulator
running iOS 27.2 passed 899 tests, including the native HTTPS trust check,
and exported LCOV. Mac Catalyst passed all 79 URLSession tests, including
native HTTPS, and exported LCOV.

```sh
DIORAMA_I02_HTTPS=1 scripts/check
TEST_RUNNER_DIORAMA_I02_HTTPS=1 scripts/coverage ios
TEST_RUNNER_DIORAMA_I02_HTTPS=1 scripts/coverage catalyst
```
