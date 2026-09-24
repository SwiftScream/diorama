# 003-D02: Task rejection and response-presentation spike

- Date: 2026-09-24
- Owning unit: [003-D02](../plans/003-clean-slate-implementation.md#003-d02--task-rejection-and-response-presentation-spike)
- Status: In progress. The owner approves DD12's native rejection amendment on
  2026-09-24. The resumed diagnostic probes pass. After considering the Linux
  response buffering and disposition failures, the owner directs continued
  Linux planning and implementation. Response disposition is now an accepted
  native limitation under the DD12/DD17 amendment below; an upstream repair is
  not required. Aggregation remains a defect affecting otherwise working
  requests. The next probes establish the native disposition baseline and
  initial request-body preservation, then expose ignored task-delegate
  assignment on Linux. The owner accepts FN-07 as another native limitation
  and directs continued D02 investigation; the remaining task/response matrix
  is outstanding.
- Authority: [DD12](../design-decisions/12-urlsession-scope.md),
  [DD17](../design-decisions/17-http-lifecycle-composition.md), and Plan 003 Q1.
- Approved model: GPT-6 Astra, `xhigh`.
- Experiment: [test matrix](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02TaskRejectionTests.swift)
  and [fixtures](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02RejectionFixtures.swift).
  The follow-up adds [diagnostic probes](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02DiagnosticTests.swift)
  and [response probes](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02ResponseTests.swift).
  The next follow-up adds [request constructor probes](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02ConstructorTests.swift)
  and [native HTTP controls](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02NativeHTTPTests.swift).
- Cross-unit handoff: [FoundationNetworking investigation context](003-D02-foundationnetworking-handoff.md)
  consolidates D01/D02 issues for the owner's separate investigator.

## Finding and review boundary

D01's owner-approved task-ownership route remains the production routing choice.
This experiment asks whether every required unsupported operation reaches a
place where the adapter can reject it. Routing cannot help an operation that
never enters the interceptor.

The initial probes do not satisfy DD12's original rejection contract. The
following observations are preserved as evidence for the subsequently approved
[native rejection amendment](../design-decisions/12-urlsession-scope.md#native-rejection-errors-amendment--2026-09-24):

- On Apple platforms, a stream task bypasses both `URLProtocol.canInit`
  overloads and `startLoading`, and connects to the loopback listener. A custom
  protocol alone therefore cannot enforce the offline exclusion.
- Apple's synchronous task-creation delegate hook can cancel stream and
  WebSocket tasks before a connection. However, delegate completion,
  `task.error`, stream-write completion, and WebSocket-receive completion expose
  `NSURLErrorDomain/-999`, which conflicts with the original requirement for a
  distinct Diorama infrastructure error. The amendment now accepts that native
  error when the adapter cancels early and reports the unsupported operation.
- An Apple WebSocket task does reach the custom protocol, but a supplied
  `DioramaD02Unsupported/1` error emerges as `NSURLErrorDomain/1`; the test's
  custom `userInfo` marker is also absent.
- On both tested Linux images, WebSocket `resume()` reports
  `NSURLErrorDomain/-1002` before either protocol-selection overload or
  `startLoading` runs. No task-creation callback is delivered. No connection
  occurs in these images, whose libcurl lacks WebSocket support. This is not
  evidence that a different libcurl build would follow the same path.

D02 stopped at its required review checkpoint after these probes. The owner
then approved the narrow native-error exceptions documented below. The
no-live-fallback rule remains mandatory, and no production implementation is
introduced by this spike.

## Owner-approved resolution — 2026-09-24

The owner accepts native Linux WebSocket refusal on the tested profiles that
reject before interception and any network access. No replacement error or
synthetic diagnostic is required for that pre-interception refusal.

For Apple stream and WebSocket tasks, the adapter cancels in the synchronous
task-creation callback, records a structured unsupported-operation diagnostic
for the owning attachment, and preserves Foundation's ordinary cancellation
error. Cancellation precedes invoking the diagnostic sink or other consumer
callbacks to protect against reentry. The diagnostic follows the existing
ledger, sink, and post-finish reporter contracts.

This resolves the policy blocker and allows the remaining D02 investigations.
At that checkpoint, the probes verify early cancellation and native error
propagation, but do not verify diagnostic attribution, delivery, or reentry
safety. The follow-up below supplies native-hook evidence for those checks;
D02 remains incomplete.

## Original experiment design

The isolated package uses no production imports or added dependencies. A custom
protocol claims every request and task and immediately fails with an identifiable
test error. The data-task case is a control; deliberately rejecting it does not
propose rejecting supported production requests. Each protocol start records
the native task family and whether the request still has `httpBodyStream`.

A nonblocking TCP listener binds only `127.0.0.1` on an ephemeral port. The test
polls it and immediately closes accepted sockets. One accepted connection is
positive evidence of native bypass, without using an external server. Each test
cancels or invalidates its session. Negative connection observations accompany
terminal rejection, not a claim that a short sleep proves general quiescence.

The second Apple probe cancels inside `urlSession(_:didCreateTask:)`, asserts
that the callback ran before the task factory returned, then exercises resume
and the native stream-write/WebSocket-receive error channels. It demonstrates
both early cancellation and the limits of rewriting only delegate completion.
It does not implement a production delegate proxy or a diagnostic ledger.

The suite is serialized because protocol observations share a static mutex.
Delegate observations use a separate mutex. The listener is owned and polled by
one test. D02 adds no unchecked sendability, unsafe isolation, global protocol
registration, availability increase, or warning suppression. Three-second
monotonic deadlines bound asynchronous observation; their exact duration is not
a behavior assertion.

## Original executed matrix

Both Linux columns have the same result; Apple columns were executed separately.
“Custom error” means the test's supplied error domain reaches task completion.

| Probe | macOS 27.0 | iOS 27.0 Simulator | Swift 6.4.0 Linux | Pinned Linux snapshot |
| --- | --- | --- | --- | --- |
| Data-task rejection control | Custom error; zero connections | Same | Same | Same |
| Upload from in-memory data | Upload task identified; custom error; zero connections | Same | Same | Same |
| Streamed upload | Upload task identified; custom error; zero connections | Same | Same | Same |
| Download from URL | Download task identified; custom error; zero connections | Same | Same | Same |
| WebSocket via protocol | Intercepted; error domain rewritten; zero connections | Same | No interception; native unsupported-URL error; zero connections | Same |
| Stream via protocol | **Bypass: one connection, no protocol callbacks** | Same | API unavailable; excluded at compilation | Same |
| Cancel WebSocket at task creation | Zero connections; native cancellation on all checked channels | Same | No task-creation hook; not executed | Same |
| Cancel stream at task creation | Zero connections; native cancellation on all checked channels | Same | Stream API unavailable | Same |
| `data:` scheme | Custom error | Same | Same | Same |
| Custom non-HTTP scheme | Custom error | Same | Same | Same |
| Data task with `httpBodyStream` | Stream still visible; custom error; zero connections | Same | Same | Same |

Apple calls task-based `canInit(with:)` for the intercepted task families.
Linux calls request-based `canInit(with:)`; `startLoading` still exposes the
task, allowing the tested upload/download distinction. The WebSocket Linux
failure occurs before either overload.

The streamed-upload fixture supplies its body through `needNewBodyStream`,
without putting a body on the upload request. Apple requests that stream once
by the time rejection completes; Linux does not request it in this path. The
probe establishes rejection before a connection, not absence of preparatory
delegate callbacks.

There are **11 parameter cases on each Apple platform: 9 pass, 2 fail**.
The two failed cases are protocol rejection of WebSocket and stream tasks,
with four assertion failures in total. There are **8 cases on each Linux image:
7 pass, 1 fails**, with two assertions failing for WebSocket rejection.
The failures are retained as ordinary failing assertions, not marked expected
or skipped. These are the original protocol-only/custom-error assertions;
their counts do not assess the subsequently approved rejection policy or the
new diagnostic probes. The
focused SwiftPM commands exit 1; the completed iOS test command
exits 65. These commands do not run D01's separately documented historical
controls. No replay-safety acceptance claim follows from passing control cases.

## Original source diagnosis

The Xcode 27 Foundation header `NSURLSession.h`, lines 1692–1699, specifies that
[`urlSession(_:didCreateTask:)`](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession%28_%3Adidcreatetask%3A%29)
is synchronous and runs before task creation returns, outside the delegate
queue. It is available from macOS 13/iOS 16, below the repository's deployment
floors. The spike confirms that ordering for these task factories. Native
[`URLSessionTask.error`](https://developer.apple.com/documentation/foundation/urlsessiontask/error)
is read-only to the consumer. A delegate proxy can report an infrastructure
diagnostic, but that alone cannot replace the error returned by a stream write
or WebSocket receive operation on the returned native task.

In the inspected Swift 6.4.0 FoundationNetworking source, commit
`d29d01ba165f6957141e07ea7fe8144ab491bc24`,
[`URLSessionWebSocketTask.resume()`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L939-L957)
checks libcurl WebSocket support first. When unavailable, it reports an
unsupported-URL error through the native protocol client and returns without
calling the superclass implementation. This explains the observed absence of
custom protocol selection. The release's
[`URLSessionTaskDelegate`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionDelegate.swift)
has no `didCreateTask` requirement. Declaring a same-named method in the test
delegate does not make FoundationNetworking invoke it.

## Diagnostic and response follow-up — 2026-09-24

The owner asks to continue D02 and pause if an issue requires consideration.
The new probes first exercise the approved diagnostic path, then a minimal
multi-chunk response and `.cancel` disposition. They reproduce two further
FoundationNetworking failures, so exploration initially stops at this boundary.
The owner subsequently approves continued Linux work and the disposition
exception recorded below.

### Diagnostic result

For Apple stream and WebSocket tasks, two adapter-owned delegates identify
their respective attachment, cancel in `didCreateTask`, append a structured
test diagnostic, and invoke a sink. The sink checks that its diagnostic is
already retained, then immediately resumes the same task and attempts a stream
write or WebSocket receive before the factory returns. Both attachments retain
and deliver exactly their own diagnostic. The native task, delegate completion,
and operation completion report cancellation, with zero loopback connections.
Both task-family cases pass on macOS and iOS Simulator.

This proves that the native callback permits the approved ordering and
attribution under the exercised reentry. A small mutex-protected test ledger
stands in for the already separate production diagnostic reporter. The spike
does not import DioramaCore, reimplement its full reporter, or establish
production finalization/retention conformance. It adds no unsafe sendability or
isolation annotations. Native task-state visibility can lag `cancel()`; the
probe asserts terminal errors and zero connections, not an immediate state
property transition.

On both Linux profiles, a separate probe confirms native WebSocket refusal:
no creation callback, no manufactured diagnostic, no connection, and
`URLError.unsupportedURL` through both task completion and WebSocket receive.

### Response result

The controlled protocol emits a 203 HTTP response with a custom response
header and content length 12, then two six-byte `didLoad` calls containing
`first-` and `second`, then finishes. All protocol calls occur synchronously in
`startLoading`. Each session disables caching and targets a loopback listener
to detect fallback. The delegate queue is serial. The `.cancel` case answers
the response callback with `.cancel` without separately calling `task.cancel()`.

| New probe | macOS 27.0 | iOS 27.0 Simulator | Stable Swift 6.4 Linux | Pinned Linux snapshot |
| --- | --- | --- | --- | --- |
| Stream diagnostic attribution and reentrant sink | Pass | Pass | API unavailable | API unavailable |
| WebSocket diagnostic attribution and reentrant sink | Pass | Pass | Native refusal probe passes | Native refusal probe passes |
| Delegate receives complete body | `first-second`; one 12-byte callback | Same | `first-second`; two 6-byte callbacks | Same |
| Completion handler receives complete body | `first-second` | Same | **Fail: only `second`** | Same |
| Async `data(from:)` receives complete body | `first-second` | Same | **Fail: only `second`** | Same |
| Response `.cancel` prevents body delivery | Empty body; native cancellation | Same | **Fail: both chunks delivered, successful completion** | Same |

All new cases observe zero loopback connections. Response status and the custom
header survive every successful-response presentation. Apple coalesces the two
back-to-back chunks for the data delegate; this probe establishes complete
bytes, not fidelity of separately timed chunk delivery. Linux delegate delivery
retains both chunks, while its completion and async consumers lose the first.

The focused follow-up has **6 parameter cases on each Apple platform, all
passing**, and **5 cases on each Linux profile: 2 pass, 3 fail**. The three
Linux failures produce five assertion failures. The macOS and iOS commands
exit 0; both Linux commands exit 1. No failed expectation is suppressed. These
counts exclude the original rejection tests and D01's historical controls.

### FoundationNetworking diagnosis and owner resolution

The inspected Swift 6.4.0 release source at
`d29d01ba165f6957141e07ea7fe8144ab491bc24` explains the observed custom-protocol
behavior:

1. [`_ProtocolClient.urlProtocol(_:didLoad:)`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L1314-L1335)
   assigns each new chunk to `properties[.responseData]`, replacing the previous
   value. The
   [completion path](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L1201-L1206)
   returns that single value. The
   [async convenience](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSession.swift#L761-L775)
   uses the same completion behavior.
2. The [response callback path](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L1080-L1089)
   supplies a disposition completion handler that ignores its argument. The
   observed `.cancel` therefore does not gate data or successful completion.

These experiments concern the custom `URLProtocolClient` path. The native
[`HTTPURLProtocol.didReceiveResponse()`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/HTTP/HTTPURLProtocol.swift#L515-L546)
also uses the ignored-disposition path and attributes that choice to unresolved
transfer pausing. Although
[`NativeProtocol.swift`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/NativeProtocol.swift#L505-L544)
contains decision-handling helpers, searching `Sources/` finds no caller of
`askDelegateHowToProceedAfterCompleteResponse`; the native pause/unpause state
transitions also contain unfinished `fatalError` paths. Their presence does
not prove working native disposition handling or a fundamental limitation of
current libcurl. At this checkpoint, a native-server control was still needed;
the later native baseline below supplies it. Explicit
[`task.cancel()`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L375-L410)
uses a separate stop-loading path. Unanswered dispositions were untested at
this checkpoint; task conversion remains untested. These source findings are
retained as historical context, not as required upstream repair work.

### Accepted Linux disposition limitation — 2026-09-24

The owner approves preserving the demonstrated native live limitation under
the [DD12 exception](../design-decisions/12-urlsession-scope.md#foundationnetworking-response-disposition-exception--2026-09-24)
and [DD17 recording amendment](../design-decisions/17-http-lifecycle-composition.md#foundationnetworking-response-disposition-exception--2026-09-24).
The former handoff issue FN-02 is removed from the upstream investigation list;
fixing it is not a Diorama prerequisite. The original probe and failing
expectation remain evidence of the native difference, not a requirement that
Diorama repair FoundationNetworking.

The approved implementation must preserve native record/passthrough outcomes,
avoid depending internally on response-disposition cancellation, and diagnose
interactions that cannot be represented by the supported recording model.
Such candidates cannot be published; successful live delivery must not be
rewritten as a cancellation failure. Replay recordings requiring effective
cancellation or pending-decision gating are rejected on a bridge lacking that
capability. Explicit task cancellation, cleanup, and offline replay remain
required. The native baseline control must verify the claimed parity; a new
failure introduced by Diorama is outside this exception.

The aggregation failure FN-01 remains a correctness problem for segmented
completion/async requests. The [Q1 continuation policy](../plans/003-clean-slate-implementation.md#q1--urlprotocol-evidence-versus-production-task-division-resolved-by-owner-2026-09-06)
allows Linux implementation to continue while that defect is addressed. The
[handoff](003-D02-foundationnetworking-handoff.md) retains its focused repair
proposal and possible later refactoring. No upstream patch or production
implementation is introduced by this documentation update.

## Constructor and native HTTP follow-up — 2026-09-24

The owner directs continued D02 investigation. This follow-up adds two
isolated fixtures, with no production imports, dependencies, unsafe sendability,
or isolation annotations.

### Initial request body and constructor results

The constructor matrix crosses five presentations with four initial body
forms: absent, empty `Data`, four binary bytes, and a caller-supplied
`InputStream`. Presentations are the URLRequest delegate, completion-handler,
async `data(for:)`, async `data(for:delegate:)`, and a data task whose
`delegate` is assigned before `resume()`. The protocol returns a single
two-byte response, deliberately avoiding the already demonstrated aggregation
defect. It records the body/stream fields on its request and on the task's
original/current requests. An ephemeral loopback listener detects fallback.

Apple normalizes an empty body to absence and a nonempty body to a stream in
`URLProtocol.request` and `task.currentRequest`. However,
`task.originalRequest` preserves absent, empty, binary data, and an explicitly
supplied stream as distinct input forms. Linux preserves those forms on all
three inspected requests. Thus rejecting every protocol request with a stream
would incorrectly reject ordinary in-memory bodies on Apple. For an initial
request, the task's original request provides the tested classification and
body bytes. This does not establish how to recover a redirect-derived body;
that remains D03 work. The stream case returns a test response only to observe
classification; it does not propose supporting streamed bodies in production.

All presentations produce the expected status and complete single-chunk body,
and every constructor case observes zero connections. Apple delivers explicit
task overrides to the assigned task delegate. Linux instead delivers to the
session delegate, even though the task's delegate getter returns the assigned
object. The four override cases retain failed expectations for the expected
recipient. The async overload's explicit delegate follows a different path:
Linux invokes that delegate's response callback and successfully returns the
body. Apple returns the async body without invoking the supplied delegate's
response callback in this fixture. Redirect, authentication, and full proxy
equivalence are not established by this successful-result control.

### Native response-disposition baseline

A nonblocking loopback server accepts one ordinary HTTP request. The session
installs no custom protocol. The server sends an HTTP head plus `first-`, then
sends `second` after observing the response callback. The response explicitly
declares `Content-Type: application/octet-stream`; the earlier fixture without
that field stalled waiting for Apple's response callback while part of the
body remained unsent. That fixture issue is corrected before the reported run.

The callback either allows, cancels by disposition, retains its completion
handler, or explicitly calls `dataTask.cancel()` and answers `.allow`.
The retained-handler case sends the rest of the response before answering.
All waits have bounded monotonic deadlines. The server socket and fixture
state remain owned by the test task, while delegate observations use a mutex.

| Native operation | Apple Foundation | Both tested Linux profiles |
| --- | --- | --- |
| `.allow` | Complete `first-second` body | Same |
| Response `.cancel` | No body; `NSURLErrorDomain/-999` | Both chunks; successful completion |
| Retained response decision | No body or completion until `.allow` | Both chunks and successful completion before `.allow` |
| Explicit `task.cancel()` | Native cancellation | Native cancellation; the initial in-flight chunk may arrive first |
| Assign `task.delegate` before resume | Assigned delegate receives response and completion | Session delegate receives both; assigned delegate receives neither |

This establishes the native Linux basis for the accepted response-disposition
exception, including ignored pending-decision gating. Explicit task cancellation
works in this control and remains distinct from answering `.cancel`.
The prior custom-protocol `.cancel` failure matches this native limitation.
Timed custom-protocol delivery, an open custom-protocol decision, forwarding
parity, and finalization/quiescence still need their own evidence. This control
does not claim that cancellation forbids a chunk already in flight.

The focused follow-up has **25 parameter cases per platform**: 20 constructor
cases, four native disposition cases, and one native delegate-assignment case.
All 25 pass on macOS and iOS Simulator. Each Linux profile has **20 pass and
5 fail**, with 15 failed assertions, all concerning property-assigned delegate
dispatch. There are no suppressed or expected failures. The macOS and iOS
commands exit 0; the Linux commands exit 1. All four compile with warnings
treated as errors. The iOS result bundle reports no runtime warnings.

### New review finding: task delegate assignment

The final native test sets `task.delegate` before resuming an ordinary HTTP
request and verifies the getter's identity. Both Linux profiles nevertheless
send response and completion to the session delegate. This reproduces the
constructor finding without any custom protocol or Diorama involvement.
It is recorded as [FN-07](003-D02-foundationnetworking-handoff.md#fn-07--assigning-taskdelegate-does-not-select-the-callback-recipient)
with the release-source dispatch diagnosis. Its failing assertions remain
visible, while successful response bytes are checked independently.

The owner accepts this as another native Linux limitation and directs continued
D02 investigation. It is not a prerequisite upstream fix or a blocker to the
remaining spike. Task-ownership routing does not depend on the setter, and
private forwarding can use a delegate supplied when creating its session.
The adapter must preserve effective native delegate selection rather than
assuming the task's delegate getter identifies the actual callback recipient.
The tested async delegate overload remains distinct from the property setter
and must not be disabled by this finding. The existing conformance boundary
for task-delegate forms applies; this clarification adds no production
workaround or claim of equivalent property-assigned delegation. The initial
review pause is resolved, and D02 continues.

## Remaining investigations

The following D02 cases remain **untested**, after these review checkpoints:

- multi-chunk responses through URLRequest and task-delegate presentations;
- forwarding of the recovered in-memory body and classification after native
  request rewriting (redirect-specific evidence belongs to D03);
- separately timed response chunks and unanswered/open dispositions;
- the remaining intercepted/native disposition parity checks; effective
  cancel/open behavior is required only where that capability is advertised;
- file uploads, upload/download resume forms, and response-driven conversion;
- reliable optional delegate capability detection and enforcement around
  task-delegate overrides, beyond observing their dispatch behavior;
- cache bypass with seeded responses across those presentations;
- the remaining non-HTTP and HTTPS paths, with zero live access for rejected
  operations on the chosen platform profiles.

These investigations remain isolated spike work. Rejection in an actual
production record/replay/passthrough adapter is later production conformance
work; D02 does not add that adapter. Linux's missing task-creation hook no
longer blocks the accepted native WebSocket refusal on the tested profiles.
Any profile that supports WebSockets still requires fresh rejection evidence.

D01 task ownership remains useful for supported intercepted tasks. This result
does not reopen that routing choice. D03 and production URLSession work must
not depend on D02 as a passed capability gate.

## Environment and reproduction

The macOS host is arm64 macOS 27.0 build `26A428`; Xcode 27.0 build `27A266a`
provides Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`). The
iPhone 17 simulator runs iOS 27.0 build `24A434`. Package minimums remain
macOS 15/iOS 18; runs on those older OS versions are not claimed.

Both Linux runs use x86_64 Ubuntu 24.04 and
`libcurl4-openssl-dev:amd64 8.5.0-2ubuntu10.13`:

- Stable `swift:6.4.0-noble`: Swift `6.4 (swift-6.4-RELEASE)`, OCI index
  `sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9`,
  amd64 image `sha256:3fd7537e088df14007e5c9dd71a1b4d91b19067df727b17294ae0f6ea79f6423`.
- Repository snapshot `swiftlang/swift` at
  `sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`:
  Swift `6.4.2-dev (LLVM 15622a86b1749a9, Swift d2e983b81b18217)`.

### Original rejection commands

From the repository root:

```sh
swift test --package-path Spikes/URLSessionInterception \
  --scratch-path .build/d02-spike -Xswiftc -warnings-as-errors \
  --filter D02TaskRejectionTests

container run --rm --arch x86_64 --cpus 2 --memory 4G \
  --mount type=bind,source="$PWD",target=/source,readonly --workdir /work \
  swift:6.4.0-noble \
  bash -lc 'cp -R /source/Spikes/URLSessionInterception /work/ && cd /work/URLSessionInterception && swift --version && dpkg-query -W libcurl4-openssl-dev && swift test -Xswiftc -warnings-as-errors --filter D02TaskRejectionTests'
```

The snapshot command is identical with the image argument replaced by
`swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`.
From `Spikes/URLSessionInterception`:

```sh
xcodebuild test -quiet -scheme URLSessionInterception-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  -derivedDataPath ../../.build/d02-ios-final-derived \
  -resultBundlePath ../../.build/d02-ios-verified.xcresult \
  -only-testing:URLSessionInterceptionTests/D02TaskRejectionTests \
  -collect-test-diagnostics never \
  IPHONEOS_DEPLOYMENT_TARGET=18.0 SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
```

Automatic simulator diagnostic-archive collection delayed an earlier run after
all test cases finished. That command was interrupted; the final command above
disables only the diagnostic archive, retaining the test failures and xcresult.
Use a fresh result-bundle path on subsequent runs.

### Follow-up diagnostic and response commands

The follow-up uses the same four toolchain/runtime profiles. From the
repository root:

```sh
swift test --package-path Spikes/URLSessionInterception \
  --scratch-path .build/d02-spike -Xswiftc -warnings-as-errors \
  --filter 'D02(Diagnostic|Response)Tests'

container run --rm --arch x86_64 --cpus 2 --memory 4G \
  --mount type=bind,source="$PWD",target=/source,readonly --workdir /work \
  swift:6.4.0-noble \
  bash -lc 'cp -R /source/Spikes/URLSessionInterception /work/ && cd /work/URLSessionInterception && swift --version && dpkg-query -W libcurl4-openssl-dev && swift test -Xswiftc -warnings-as-errors --filter "D02(Diagnostic|Response)Tests"'
```

The pinned snapshot run substitutes the same digest given above. From
`Spikes/URLSessionInterception`:

```sh
xcodebuild test -quiet -scheme URLSessionInterception-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  -derivedDataPath ../../.build/d02-ios-final-derived \
  -resultBundlePath ../../.build/d02-ios-responses.xcresult \
  -only-testing:URLSessionInterceptionTests/D02DiagnosticTests \
  -only-testing:URLSessionInterceptionTests/D02ResponseTests \
  -collect-test-diagnostics never \
  IPHONEOS_DEPLOYMENT_TARGET=18.0 SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
```

The iOS result bundle reports six passed parameter cases, no skipped or expected
failures, and no runtime warnings. Its exported test-runner output confirms the
response bytes and chunk observations in the follow-up matrix.

### Constructor and native HTTP commands

The constructor/native follow-up uses the same four environment profiles.
From the repository root:

```sh
swift test --package-path Spikes/URLSessionInterception \
  --scratch-path .build/d02-spike -Xswiftc -warnings-as-errors \
  --filter 'D02(NativeHTTP|Constructor)Tests'

container run --rm --arch x86_64 --cpus 2 --memory 4G \
  --mount type=bind,source="$PWD",target=/source,readonly --workdir /work \
  swift:6.4.0-noble \
  bash -lc 'cp -R /source/Spikes/URLSessionInterception /work/ && cd /work/URLSessionInterception && swift --version && swift test -Xswiftc -warnings-as-errors --filter "D02(NativeHTTP|Constructor)Tests"'
```

The pinned snapshot substitutes the image digest above. From
`Spikes/URLSessionInterception`:

```sh
xcodebuild test -quiet -scheme URLSessionInterception-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  -derivedDataPath ../../.build/d02-ios-final-derived \
  -resultBundlePath ../../.build/d02-ios-constructors-native.xcresult \
  -only-testing:URLSessionInterceptionTests/D02NativeHTTPTests \
  -only-testing:URLSessionInterceptionTests/D02ConstructorTests \
  -collect-test-diagnostics never \
  IPHONEOS_DEPLOYMENT_TARGET=18.0 SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
```

Use a fresh result-bundle path when repeating the iOS command. The 25-case
counts above exclude all earlier D01/D02 controls and retained failures.

Compilation passes with warnings treated as errors on all four environments.
The canonical `scripts/lint` gate passes with zero violations. Documentation
links and the complete proposed diff pass the V-doc checks. Build products,
console logs, and xcresult bundles remain local generated artifacts. No hosted
CI or production test-suite result is claimed by this isolated V-spike report.
