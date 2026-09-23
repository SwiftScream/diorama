# 003-D02: Task rejection and response-presentation spike

- Date: 2026-09-24
- Owning unit: [003-D02](../plans/003-clean-slate-implementation.md#003-d02--task-rejection-and-response-presentation-spike)
- Status: In progress. The owner approves DD12's native rejection amendment on
  2026-09-24, resolving the rejection-error policy checkpoint. Diagnostic
  verification and the remaining task/response matrix are still outstanding.
- Authority: [DD12](../design-decisions/12-urlsession-scope.md),
  [DD17](../design-decisions/17-http-lifecycle-composition.md), and Plan 003 Q1.
- Approved model: GPT-6 Astra, `xhigh`.
- Experiment: [test matrix](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02TaskRejectionTests.swift)
  and [fixtures](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02RejectionFixtures.swift).

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
It does not complete D02: the current probes verify early cancellation and
native error propagation, but do not verify diagnostic attribution, delivery,
or reentry safety. Those checks and the rest of the matrix below are required.

## Experiment design

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

## Executed matrix

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
their counts do not assess the subsequently approved rejection policy. The
amended rejection path still needs its own diagnostic verification. The
focused SwiftPM commands exit 1; the completed iOS test command
exits 65. These commands do not run D01's separately documented historical
controls. No replay-safety acceptance claim follows from passing control cases.

## Source diagnosis

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

## Remaining investigations

The following D02 cases remain **untested**, because the rejection checkpoint
was reached first:

- diagnostic attribution to the owning attachment, ledger/sink delivery,
  cancellation before sink reentry, and unchanged native rejection errors
  through the approved Apple path;
- successful URL/URLRequest, completion-handler, delegate, async, and
  task-delegate data presentations;
- in-memory body preservation and absent-versus-empty distinction;
- response heads, multiple chunks, and allow/cancel/unanswered dispositions;
- file uploads, upload/download resume forms, and response-driven conversion;
- reliable optional delegate capability detection and task-delegate overrides;
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

Compilation passes with warnings treated as errors on all four environments.
The canonical `scripts/lint` gate passes with zero violations. Documentation
links and the complete proposed diff pass the V-doc checks. Build products,
console logs, and xcresult bundles remain local generated artifacts. No hosted
CI or production test-suite result is claimed by this isolated V-spike report.
