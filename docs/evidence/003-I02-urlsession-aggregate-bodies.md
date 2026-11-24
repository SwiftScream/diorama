# 003-I02 — In-memory bodies and aggregate URLSession data tasks

The owner confirms this unit and selects GPT-6.2 Sol with `high` reasoning.
The review branch is stacked on [I01](003-I01-instrumented-session-get.md).

## Supported profile

On the supported Apple targets, instrumented sessions accept HTTP(S) data tasks with an
absent body or an in-memory `Data` body. The aggregate presentations are
`dataTask(with:completionHandler:)` for a URL or URLRequest, async
`data(from:)` and `data(for:)`, and HTTPTypesFoundation's async `data(for:)`.
Overloads with an explicit nil task delegate use the same path. A supplied
task delegate, streamed request body, or another unsupported task family fails
admission. Replay setup validates the complete fixture against the aggregate
profile, which also allows I01's open horizon.

Foundation can expose an in-memory body as a stream on the intercepted
protocol request. The bridge checks the task's original request to distinguish
a caller-supplied stream, absent content, and present empty bytes. It restores
the original body on a local copy of the intercepted request. The live
transport forwards that request with its original fields and copied session
settings. Stable preparation redacts credential fields in the recording and
match input.

Requests match on exact logical body bytes, including owned resource bytes.
The private completion handler observes the final aggregate head and content.
The HTTP accumulator selects inline or resource storage and derives
Content-Length only where the existing proof succeeds. Replay delivers the
head, content, and conclusion through the same native lifecycle, so Foundation
returns the aggregate only after the recorded conclusion. These are logical
application bytes. Native framing, automatically inserted fields, and
presentation depend on Foundation.

## Verification

The [native bridge suite](../../Tests/DioramaURLSessionTests/SessionBridgeTests.swift)
exercises every aggregate presentation in record and replay. A loopback origin
compares native passthrough and record traffic, including raw JSON spelling,
different same-length binary PATCH bodies, cookie handling, authorization,
and response length. Replay reloads the persisted JSON and resources, claims
the bodies in reverse order, and makes no connection to the origin even on a
same-length mismatch. Other cases distinguish absent and empty bodies, test
stream and delegate admission, and verify aggregate timing and cancellation.
The optional HTTPS test uses ordinary trust handling against a public origin.

The canonical macOS gate reports 875 tests and passes strict formatting and
lint, compiler probes, release builds, and the Random and Date examples.
The full `DioramaURLSessionTests` bundle reports 56 tests on the iPhone 17
Simulator running iOS 27.2, with the package compiled for iOS 18. Both
platforms pass the opt-in HTTPS test. The full local Simulator run stops
after the URLSession bundle when later bundles spend several minutes in
XCTest's Objective-C class discovery. The targeted URLSession rerun succeeds.
Before the I01 platform update, 739 tests pass in the CI-pinned x86_64 Swift
6.4.2 Linux image, including the experimental bridge checks.

```sh
DIORAMA_I02_HTTPS=1 swift test -Xswiftc -warnings-as-errors --filter SessionBridgeTests
scripts/check
TEST_RUNNER_DIORAMA_I02_HTTPS=1 xcodebuild test -scheme Diorama-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.2' \
  -only-testing:DioramaURLSessionTests -parallel-testing-enabled NO -jobs 4 \
  IPHONEOS_DEPLOYMENT_TARGET=18.0 SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_SUPPRESS_WARNINGS=NO
# Inside the CI-pinned Linux image
swift test -j 2 -Xswiftc -warnings-as-errors
```
