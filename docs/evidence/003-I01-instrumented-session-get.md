# 003-I01 — Bodyless GET through a native URLSession

`DioramaURLSessionSystem.instance(named:configuration:)` supplies a fresh
`URLSession` for each execution. The owner confirms the unit and selects
GPT-6.2 Astra with `xhigh` reasoning. The native adapter uses the
[approved HTTPTypesFoundation product](../dependency-policy.md#approved-http-package-adoption--003-h01)
from the existing Swift HTTP Types 1.8.0 resolution.

## Supported behavior

| Mode | macOS, iOS, and Mac Catalyst |
| --- | --- |
| Record | A bodyless HTTP(S) GET forwards to the origin through a private session. A successful aggregate result records the prepared response head, exact content and completion. |
| Replay | The attachment claims a matching GET and schedules its response, unsegmented content and conclusion. An open interaction stays pending until cancellation or finish. A miss fails offline. |
| Passthrough | An ordinary native session uses the copied configuration, consumer delegate and delegate queue. |

For example, the same application call can read live bytes while recording and
fixture bytes during replay.

```swift
let system = try DioramaURLSessionSystem.instance(named: "service", configuration: .ephemeral)
let setup = try Diorama(file: fixture, scenarioID: "get", mode: mode, systems: system)
let result = try await setup.execute { _, session in
    try await session.data(from: url).0
}
```

Record and replay accept a default or ephemeral configuration and own a serial
delegate queue. Setup rejects background configurations, consumer delegates and
custom delegate queues for these modes. The outer session installs Diorama's
interceptor first. Both configurations disable URL caching. The private
transport retains the consumer protocol order, cookie and credential settings,
and original request fields. Each admitted GET uses a private completion-handler
task on its own session. The recording uses standard HTTP preparation and
orders field names at Foundation's dictionary boundary.

[I03A](../plans/003-clean-slate-implementation.md#003-i03a--share-the-recording-forwarding-session)
schedules one forwarding session per recording attachment per execution before
I04 adds segmented delivery.

The private data task observes one completion-handler result. The head and
body timings reflect that observation. If the operation is still waiting for
its result at the recording horizon, its interaction remains open. Request
bodies, segmented delivery, trailers and consumer decisions are outside this
profile. Live failures, redirects and HTTP challenges make the candidate
unpublishable. The caller still receives the native live outcome. Setup checks
the complete replay fixture before activation.

A macOS review probe confirms that a bodyless GET through
`URLSession.bytes(from:)` can complete with a buffered response. In record mode,
the caller receives the head and bytes after the private task completes. The
owner accepts buffering for I01. The
[I04 conformance test](../plans/003-clean-slate-implementation.md#003-i04--segmented-delegate-delivery-and-response-disposition)
must verify streaming in record and replay.

Uploads, downloads, streamed request bodies, other methods and non-HTTP schemes
are rejected before recording or claiming. The creation hook cancels native
stream and WebSocket tasks. A supplied per-task delegate also fails admission.
The Linux package graph omits `DioramaURLSession` and its fixture tooling.
The isolated spike retains the FoundationNetworking evidence, including
FN-05, FN-08, and FN-19. [FoundationNetworking handoff](003-D02-foundationnetworking-handoff.md)

## Ownership and finish

The Apple creation hook identifies candidate sessions by task object identity.
Foundation's outstanding task list confirms membership. Each session orders its
asynchronous lookups and replay starts. The forwarding executor rechecks the
lease, task and cancellation before admitting work. Missing or ambiguous
ownership fails the operation. A default task retains the session delegate for
diagnostic attribution even when lookup fails. No route token enters the
request, matcher, wire fields or fixture.

Every mode invalidates its returned session at finish. Callers can invalidate
passthrough sessions themselves. Creating new tasks on an invalidated session
is invalid native use. Already admitted live tasks may finish after recording
ends. Their forwarding delegate holds a weak recorder, and closed Core state
ignores further capture. Replay closes admission, removes its route, stops open
deliveries, cancels their native tasks, and joins native invalidation and a
delegate-queue barrier. Startup rollback uses the same lifecycle hooks.
[Native invalidation decision](../design-decisions/12-urlsession-scope.md#session-invalidation-amendment--2026-09-26)

`SessionDelivery` is the single `@unchecked Sendable` boundary added here.
Foundation hands it a non-Sendable `URLProtocol` instance. A recursive lock
serializes client callbacks with stop, including same-thread reentry.
Terminal handoff takes the instance exactly once. Private task creation and
cancellation run on the forwarding queue. The blocked native completion test
also checks that finalization waits for callback return.

## Verification

The [bridge tests](../../Tests/DioramaURLSessionTests/SessionBridgeTests.swift)
record and replay through the public factory, then replay a separate
[hand-authored fixture](../../Tests/DioramaURLSessionTests/Fixtures/bodyless-get.json).
Two overlapping executions request the same URL and receive their own live and
recorded bytes. The tests count origin requests, check diagnostic attribution
and publication refusal, and exercise cancellation, delayed and ambiguous
lookup, startup rollback, native callback drainage, and post-horizon live
completion. The same native bridge suite runs on Mac Catalyst.

On arm64 macOS 27.2.1 with Xcode 27.2 (27B52) and Swift 6.4.2, the canonical
macOS gate passes 870 tests, strict lint, compiler probes, release builds, and
the Random and Date examples. The original I01 iPhone 17 simulator run on
iOS 27.2 passes 869 tests, including all 14 bridge tests.

`scripts/coverage catalyst` builds for Mac Catalyst 18.0 on the same Mac
host, passes 51 tests including all 14 bridge tests, and exports LCOV with
executed URLSession coverage. In the pinned x86_64 Swift 6.4.2 Linux container,
`swift package dump-package` confirms the graph retains `DioramaHTTP` and
omits the `DioramaURLSession` product and targets. All 700 portable tests pass.

```sh
swift test -Xswiftc -warnings-as-errors --filter SessionBridgeTests
scripts/check
scripts/coverage catalyst
xcodebuild test -scheme Diorama-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.2' \
  -parallel-testing-enabled NO -jobs 4 \
  IPHONEOS_DEPLOYMENT_TARGET=18.0 SWIFT_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_SUPPRESS_WARNINGS=NO
# Inside the pinned Linux image, inspect the package graph and run tests
swift package dump-package
swift test -j 4 -Xswiftc -warnings-as-errors
```
