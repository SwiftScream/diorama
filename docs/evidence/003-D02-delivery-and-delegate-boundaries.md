# 003-D02: Extended delivery and delegate-boundary evidence

- Date: 2026-09-24.
- Owning unit: [003-D02](../plans/003-clean-slate-implementation.md#003-d02--task-rejection-and-response-presentation-spike).
- Approved model: GPT-6 Astra, `xhigh`.
- Status: Evidence recorded; the owner resolves the FN-08 review checkpoint
  on 2026-09-25 and authorizes the remaining D02 experiments. FN-08 requires
  resolution before claiming conformant Linux delegate interception. The
  [final D02 matrix](003-D02-completion-and-capability-matrix.md) records the
  completed remaining experiments.
- Earlier findings, accepted exceptions, and environments:
  [D02 task and response evidence](003-D02-task-rejection-and-response-presentation.md).
- Cross-agent investigation: [FoundationNetworking handoff](003-D02-foundationnetworking-handoff.md).

The owner accepts FN-07 as native Linux behavior and directs continued D02
work. This follow-up adds isolated probes for remaining task factories,
controlled body delivery, response decisions, seeded caches, and delegate
boundaries. It adds no production imports or package dependencies. The new
FN-08 visibility finding requires a repair or proven solution before relying
on the Linux delegate boundary; it does not reopen task-ownership routing.

## Executed matrix

The columns below refer to the exact macOS, iOS Simulator, stable Swift 6.4
Linux, and pinned Linux snapshot profiles in the earlier evidence. Apple
platforms are executed separately; both Linux profiles have the same findings.

| Probe | macOS 27 / iOS 27 Simulator | Both Linux profiles |
| --- | --- | --- |
| File/data uploads; URL/URLRequest downloads; delegate and completion constructors | Eight cases reject with the custom error before connection | Same |
| FTP, file, and HTTPS data-task interception | Three cases enter the custom protocol and reject before access to the origin | Same |
| Native-produced download resume data, delegate and completion constructors | Two cases identify a download and reject before another connection | Native resume support is absent in inspected source; this fixture is Apple-only |
| Native-produced upload resume data, delegate and completion constructors | Two cases identify an upload and reject before another connection | Upload-resume API absent from the inspected release |
| Separately delivered body segments, eight data-task presentations | Eight cases return complete bytes; delegate forms observe the first chunk before the second is emitted | Two delegate forms pass; six completion/async forms lose the first chunk (FN-01) |
| Allow, cancel, pending, and explicit task cancellation through a custom protocol | Four cases match native behavior | Four cases match the accepted native disposition limitation; explicit task cancellation works |
| Proxy rejects consumer download/stream conversion decisions | Two cases return a custom infrastructure error and no body | Download-conversion rejection passes; stream conversion API unavailable |
| Small `text/plain` response compared with real native HTTP | Both paths buffer the first chunk and response callback until more data arrives | Both paths deliver the first chunk immediately |
| Seeded cache, eight presentations, default and ephemeral configurations | Sixteen cases return the protocol's fresh response; zero connections | Same |
| Optional unsupported decision selectors | Four selectors distinguish empty and implementing delegates | No Objective-C optional-method query; see source boundary below |
| Creation-hook proxy installation and detection of later replacement | Four cases prove wrapping of ordinary/async creation and rejection of a later unprotected replacement | Creation hook absent (FN-05) |
| Async delegate visibility at protocol loading, URL and URLRequest overloads | Four controls distinguish supplied delegate from no supplied delegate | No-delegate controls pass; two supplied-delegate controls expose the session delegate instead (FN-08) |
| Native HTTP async delegate getter | Not needed for the Linux-specific callback control | Two cases receive callbacks on the supplied delegate while the getter identifies the session delegate (FN-08) |
| Existing native HTTP disposition/task-assignment regression | Five cases pass | Four pass; task-assignment case retains FN-07's failed assertions |

The selected command executes **60 cases on each Apple platform, all passing**.
Each Linux profile executes **52 cases: 41 pass and 11 fail**, with 13 failed
assertions: six FN-01 aggregation cases, four FN-08 getter cases, and one
existing FN-07 assignment case with three assertions. No failure is suppressed
or marked expected. The macOS and iOS commands exit 0; Linux exits 1. Strict
Swift 6 compilation with warnings treated as errors succeeds on all profiles.

## Resume and scheme evidence

[D02ExtendedRejectionTests.swift](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02ExtendedRejectionTests.swift)
uses actual Foundation-produced resume data. The download fixture sends half
of a 64 KiB response with an ETag and byte-range support, observes download
progress, then cancels while requesting resume data. A smaller partial body
did not update the native byte counter before the deadline, so the final
fixture uses 32 KiB. The resumed task reaches the protocol as a download, and
the original listener accepts no second connection.

The upload fixture uses an 8 MiB temporary file and a native upload. The server
reads the client's draft interop version (observed value 6), sends a 104
response with a local upload-resource URL, then captures native resume data
on cancellation. This minimal handshake follows the version-6 example in
[draft-ietf-httpbis-resumable-upload-05](https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-resumable-upload-05#section-4).
It does not implement a resumable-upload service. Both resumed constructors
reach protocol rejection without a second connection. Temporary input files
are removed after each case; opaque native resume data is not persisted.

The FTP/file/HTTPS cases deliberately reject at the protocol boundary. Their
result establishes interception and rejection, not successful live FTP/file
support or HTTPS trust/challenge handling. Ordinary HTTPS default handling
still belongs to D04. The positive native fixture connections are intentional
setup; the zero-connection assertions concern the subsequent rejected tasks.

## Delivery, decisions, and fixture synchronization

[Controlled delivery tests](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02ControlledDeliveryTests.swift)
emit a head, then `first-`, then `second`, then finish. Delegate presentations
must observe the first six bytes before the test emits the second. Aggregate
presentations must remain incomplete before the final delivery. This extends
FN-01 across URL/URLRequest completion and async forms, including explicit async
delegates. All intercepted cases observe zero native connections.

The binary response uses `application/octet-stream`. A separate
[text buffering control](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02TextBufferingTests.swift)
compares native and custom delivery of a small `text/plain` body. Apple's
buffering is present on both paths, while both Linux paths deliver immediately.
Changing a production response's content type to force streaming is not
proposed. The comparison establishes this exercised buffering behavior, not
every content type, chunk size, or cross-platform timing combination.

The conversion fixture wraps a consumer that requests `.becomeDownload` or
`.becomeStream`. It records the decision, makes protocol delivery terminal,
reports a custom error, then releases Foundation's response wait with `.allow`.
Answering `.cancel` instead made Apple replace the custom error with native
cancellation in the initial probe. The final ordering preserves the custom
error and delivers no body. Releasing the wait cannot emit further bytes
because the fixture's delivery object is already terminal. This is evidence
for a proxy that receives the decision; it does not prove that every possible
consumer delegate can be reached by that proxy.

FoundationNetworking marks the download-conversion case deprecated because
conversion is unimplemented. The rejection fixture constructs the release's
raw enum value 2 only to exercise the unsupported request. No warning is
suppressed, and no production conversion support is claimed. Stream conversion
is unavailable and is excluded at compilation on Linux.

The [controlled fixture](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02ControlledDeliveryFixtures.swift)
contains one new, test-only `@unchecked Sendable` wrapper for a Foundation
`URLProtocol`. Its private protocol reference and every client emission/stop
are protected by an `NSRecursiveLock`. Terminal emission clears the reference
before invoking the client; reentrant stop can acquire the same lock. No API
returns the protocol reference. Focused checks verify cancellation, terminal
rejection, and refusal of emissions after termination. This justification is
part of the reviewable spike, not approval for a production synchronization
design. D05 still must prove native callback quiescence and release behavior.

## Cache and delegate implementation findings

[Cache probes](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02CacheTests.swift)
seed a private URLCache with `cached` and verify that an ordinary native session
returns it. The copied configuration disables caching; interception returns
`fresh`. Original cache ownership remains unchanged. URLRequest presentations
explicitly request `.returnCacheDataDontLoad` to challenge the boundary.

On Apple, setting only `configuration.urlCache = nil` and its default request
policy did not normalize an explicit request policy: the request failed with
`NSURLErrorDomain/-1008` before `startLoading`. Protocol selection and
`canonicalRequest(for:)` did run. Returning a canonical request with
`.reloadIgnoringLocalCacheData` makes all sixteen cases reach interception.
This implements the already accepted cache-disabling boundary. Linux reaches
the custom protocol with caching disabled and does not call the canonicalization
hook in these controls. Production must apply the cache policy at the effective
bridge boundary, including private forwarding, rather than relying on one
configuration property alone.

[Apple delegate probes](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02DelegateBoundaryTests.swift)
detect optional body-stream replacement, cache proposal, delayed-request, and
session-challenge methods through `responds(to:)`. The creation hook sees an
explicit async delegate early enough to install a forwarding proxy. A consumer
replacing that proxy after task creation is detectable in `startLoading` and
can receive a custom infrastructure error before live access. These are
native-hook controls, not a complete production proxy or redirect/authentication
equivalence proof. Any advertised delegate surface still needs those later
conformance tests.

The inspected FoundationNetworking delegate protocols instead have Swift
requirements with default implementations and no corresponding Objective-C
optional-method query. Method-level detection is therefore not established on
Linux; protocol conformance alone does not distinguish an override from a
default. Operation-time checks remain necessary under DD12.

## FN-08 review boundary

[Async delegate visibility tests](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02AsyncDelegateVisibilityTests.swift)
show that Linux's working async delegate parameter is stored separately from
the task's public delegate property. With or without the parameter, the
protocol sees the same session delegate. The actual supplied delegate receives
its response callback while `dataTask.delegate` identifies the session delegate.
Both URL and URLRequest overloads reproduce this; the native HTTP control does
too. Apple exposes the supplied delegate to the protocol, and its creation-hook
proxy controls pass.

Unlike FN-07's ignored property assignment, this parameter selects a working
callback path that can bypass an adapter's session delegate. A guard based on
the getter cannot distinguish it from the ordinary async form. Combined with
FN-05's absent creation hook, the tested native session boundary has no proven
way to wrap or reject that hidden delegate before response delivery. Preserving
the native live result does not by itself provide faithful recording of its
decisions or enforce the unsupported-decision boundary.

The [FN-08 handoff](003-D02-foundationnetworking-handoff.md#fn-08--async-delegate-parameters-are-not-visible-through-taskdelegate)
records source locations and repair questions. On 2026-09-25 the owner records
FN-08 as an issue that needs addressing and resumes the remaining D02 work.
The defect remains an explicit conformance dependency; its resolution is not
a prerequisite to finishing the isolated spike under the existing Linux
continuation policy. No capability is silently narrowed and no new session
facade is adopted. The remaining experiments are completed in the
[final matrix](003-D02-completion-and-capability-matrix.md); later conformance
requirements remain explicit.

## Reproduction and verification

Use the same exact toolchains and runtime versions as the earlier
[environment record](003-D02-task-rejection-and-response-presentation.md#environment-and-reproduction).
From the repository root:

```sh
swift test --package-path Spikes/URLSessionInterception \
  --scratch-path .build/d02-spike -Xswiftc -warnings-as-errors \
  --filter 'D02(ExtendedRejection|ControlledDelivery|TextBuffering|Cache|DelegateBoundary|AsyncDelegateVisibility|NativeHTTP)Tests'

container run --rm --arch x86_64 --cpus 2 --memory 4G \
  --mount type=bind,source="$PWD",target=/source,readonly --workdir /work \
  swift:6.4.0-noble \
  bash -lc 'cp -R /source/Spikes/URLSessionInterception /work/ && cd /work/URLSessionInterception && swift --version && swift test -Xswiftc -warnings-as-errors --filter "D02(ExtendedRejection|ControlledDelivery|TextBuffering|Cache|DelegateBoundary|AsyncDelegateVisibility|NativeHTTP)Tests"'
```

For the snapshot, substitute
`swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`.
From `Spikes/URLSessionInterception`:

```sh
xcodebuild test -quiet -scheme URLSessionInterception-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  -derivedDataPath ../../.build/d02-ios-final-derived \
  -resultBundlePath ../../.build/d02-ios-remaining.xcresult \
  -only-testing:URLSessionInterceptionTests/D02ExtendedRejectionTests \
  -only-testing:URLSessionInterceptionTests/D02ControlledDeliveryTests \
  -only-testing:URLSessionInterceptionTests/D02TextBufferingTests \
  -only-testing:URLSessionInterceptionTests/D02CacheTests \
  -only-testing:URLSessionInterceptionTests/D02DelegateBoundaryTests \
  -only-testing:URLSessionInterceptionTests/D02AsyncDelegateVisibilityTests \
  -only-testing:URLSessionInterceptionTests/D02NativeHTTPTests \
  -collect-test-diagnostics never \
  IPHONEOS_DEPLOYMENT_TARGET=18.0 SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
```

Use a fresh result-bundle path when repeating the iOS run. `scripts/lint`
passes with zero violations. V-doc checks cover local links, anchors, status,
and `git diff --check` across the complete branch. No hosted CI or production
suite result is claimed by this isolated spike. Generated logs and result
bundles remain local artifacts.
