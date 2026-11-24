# 003-I03 — Native URLSession failure record/replay

The owner confirms this unit with the branch stacked on
[I02](003-I02-urlsession-aggregate-bodies.md).

## Native behavior

The private forwarding session uses a data delegate to observe the response
head and bytes. Its completion handler previously discarded the partial body
when Foundation reported a transport failure. The delegate buffers one
aggregate response, captures the time of the head, and records the terminal
outcome at native completion. Failed bodies keep only the bytes observed by the
forwarding session and retain their literal Content-Length. An admitted live
task can still finish after the execution freezes its aggregate recording.

The loopback fixture sends a binary response with a declared length of 80
bytes, supplies six bytes, and closes the connection after 180 milliseconds.
The binary content type lets Darwin expose the head and prefix before the
failure. The native completion API supplies a response and a URLError, with
nil data, in passthrough, record, and replay. The recording retains all six
bytes and the failure delay. Replay leaves the origin connection count
unchanged. Public delegate delivery and separate body segment timing belong
to I04.

Controlled protocol failures cover timeout, connection error, independently
reported cancellation, and an unknown numeric URL error code in both
completion constructors, both async data entry points, and HTTPTypesFoundation.
The truncated-response case checks the task error as well as the completion
error. A separate caller cancellation cancels the forwarding task and leaves
the record open. A dependency failure after the recording horizon still reaches
the live application. HTTP 404 and 503 return normal responses.

The private forwarding session enforces the original request and session
timeouts. The instrumented session uses unbounded request and resource
timeouts so it cannot race the private transport's completion or the replay
scheduler. The bridge starts with the original request and preserves the
intercepted HTTP head. This keeps Foundation's distinction between an explicit
request timeout and an inherited session timeout. The silent loopback fixture
exercises both request timeout sources and the session resource timeout.
Each recording contains an attempt failure, and replay uses the recorded
delay even with shorter request and session timeouts.

## Metadata and publication

Foundation supplies useful error identity and adds runtime task descriptions to
the NSError it delivers. The registered recording
[metadata policy](../urlsession-failure-schema-v1.md#urlsession-recording-policy)
filters those task descriptions and localized descriptions. Shared snapshot
rules cover the remaining keys. The tests preserve the failing URL and a
supported custom value, omit an underlying NSError with a healthy recording,
and verify that omission diagnostics contain keys and types without metadata
values. A native domain that exceeds snapshot bounds reaches the application
and invalidates the recording. Replay misses stay offline and use the separate
Diorama failure path.

## Verification

The original Mac Catalyst CI failure reproduces in three of eight local
repetitions. The outer task returns a timeout while the private task's
completion is still pending. This can leave an open interaction or start
finalization before the recorder captures the failure.

With timeout ownership moved to the private transport, the canonical macOS
gate passes 882 tests, including the three timeout cases and opt-in HTTPS
trust check. It also passes strict formatting and lint, compiler probes,
release builds, and the Random and Date examples. These checks use Xcode 27.2
and Swift 6.4.2.

Earlier I03 verification on the iPhone 17 Simulator uses iOS 27.2 with the
package compiled for iOS 18. The full Simulator run passes 880 tests before
the native timeout case is added. The targeted URLSession bundle then passes
63 tests, including the timeout case and opt-in HTTPS trust check.

Before the I01 platform update, 740 tests pass in the CI-pinned x86_64 Swift
6.4.2 Linux image, including the experimental bridge and registered failure
metadata checks. That run precedes the final formatting and native timeout test.

```sh
DIORAMA_I02_HTTPS=1 scripts/check
TEST_RUNNER_DIORAMA_I02_HTTPS=1 xcodebuild test -scheme Diorama-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.2' \
  -parallel-testing-enabled NO -jobs 4 IPHONEOS_DEPLOYMENT_TARGET=18.0 \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_SUPPRESS_WARNINGS=NO
# Repeat the simulator command with -only-testing:DioramaURLSessionTests.
# Inside the CI-pinned x86_64 Swift 6.4.2 Linux image
swift test -j 2 -Xswiftc -warnings-as-errors
```
