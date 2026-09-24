# 003-D02: Completion and capability matrix

- Date: 2026-09-25.
- Owning unit: [003-D02](../plans/003-clean-slate-implementation.md#003-d02--task-rejection-and-response-presentation-spike).
- Approved model: GPT-6 Astra, `xhigh`.
- Status: Complete as an isolated investigation. The owner authorizes merge
  preparation and PR creation on 2026-09-26.
  Linux conformance remains conditional on the recorded repairs and later gates.
- Prior evidence: [task and response probes](003-D02-task-rejection-and-response-presentation.md),
  [delivery and delegate boundaries](003-D02-delivery-and-delegate-boundaries.md).
- Upstream context: [FoundationNetworking handoff](003-D02-foundationnetworking-handoff.md).

On 2026-09-25 the owner records FN-08 as an issue that needs addressing and
authorizes the remaining D02 work. A working explicit async delegate must
become observable for faithful interception or reliable rejection. Its current
hidden callback path is not an accepted inherited limitation. The required
repair remains open while the isolated investigation continues under Q1.

## Final investigation scope

The follow-up closes the remaining initial-body and task-factory experiments:

- [Body forwarding](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02BodyForwardingTests.swift):
  twelve cases compare native HTTP and intercepted/private-forwarded POSTs for
  absent, empty, and binary in-memory bodies, across delegate, completion,
  async, and explicit async-delegate presentations. Four more cases reject
  original body streams before private forwarding.
- [Async rejection](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02ExtendedRejectionTests.swift):
  eight cases cover file/data upload and URL/URLRequest download conveniences,
  each with and without a supplied task delegate. Apple adds two async
  download-resume cases using real native-produced resume data. The selected
  SDK has no corresponding async upload-resume convenience: its Swift overlay
  lacks `upload(resumeFrom:delegate:)`, and a local type-check probe confirms
  `uploadTask(withResumeData:)` returns a task rather than an async result.
- Linux adds four native/intercepted download-resume failure-channel controls,
  covering delegate and completion constructors. The inspected release has no
  async download-resume convenience and no upload-resume API.

The existing fixtures also run again with the extended matrix. No production
target, public API, dependency, persisted schema, or supported platform changes.

## Initial-body forwarding findings

The initial task's `originalRequest` retains the distinction between an absent
body, empty `Data`, arbitrary bytes, and an original stream. Apple's protocol
request can expose an in-memory body through `httpBodyStream`; checking that
transformed request alone would incorrectly reject a supported request.

The fixture validates the original body form before constructing the private
request. It clears the transformed stream, restores the original in-memory
body, and normalizes cache policy. Tests assert the prepared absent/empty
distinction, POST target, content length, content type, a caller header, and
the exact binary bytes received by a real loopback HTTP server. Each positive
native or forwarded operation makes exactly one connection. Stream rejection
makes zero connections and never prepares a forwarded request.

Absent and empty POST bodies both have zero wire bytes in these controls;
their semantic distinction is preserved in preparation, not inferred from
HTTP framing. This covers the initial request only. Redirect method/body
rewriting and subsequent request identity remain D03 work.

The private session uses a data delegate, immediate response `.allow`, and the
existing synchronized test delivery wrapper. The wrapper gains native response
and binary-data inputs under its existing recursive-lock invariant; no new
unchecked sendability is introduced. The small response is an acknowledgment,
not an additional claim that FN-01 is fixed. Async return bytes and delegate
observations use separate collectors to avoid counting both presentations.

### Forwarding execution and teardown

Directly creating a second session's task inside `startLoading` traps on stable
Linux: the two work queues share a serial target, and the nested task factory
uses synchronous dispatch. [FN-09](003-D02-foundationnetworking-handoff.md#fn-09--synchronous-forwarding-reentry-traps-on-the-shared-session-queue)
records the source diagnosis and opt-in crash reproduction. The final fixture
enqueues task creation and teardown on its own serial queue and returns from
the native callback. This is compatible with asynchronous task-ownership
routing and does not require a new session facade.

A concurrent stable-Linux run also encounters a task-registry lookup trap.
[FN-10](003-D02-foundationnetworking-handoff.md#fn-10--task-registry-lookup-trap-during-the-concurrent-matrix)
records the observation without claiming an isolated cause. The final fixture
records private completion before emitting the outer terminal callback and
uses graceful invalidation for work already reported complete. Native resume
controls also observe task completion before teardown. D05 must still prove
callback quiescence, cancellation races, and forwarding-tail release; this
fixture is not that proof.

## Async and resume rejection findings

The async upload/download constructors reach the interceptor with their native
task family intact and throw the custom unsupported-operation error without
connecting. Supplying a task delegate does not bypass task-family rejection;
this does not resolve FN-08's observation of supported delegate interactions.

Apple async download resumption also reaches download-task rejection using a
native-produced resume blob. The existing upload-resume setup now waits for
the native 104 informational-response callback before cancellation. A fixed
150 ms wait had occasionally canceled before the resume handshake was ready
on iOS; a missing resume blob failed the fixture's prerequisite. No fabricated
resume data or repeated-until-passing assertion replaces that prerequisite.

Linux's delegate and completion resume constructors both fail with
`NSURLErrorDomain/-1002`, on ordinary and intercepted sessions. The task has no
original request, no protocol starts, and no connection occurs. The controls
use deliberately invalid input; the source establishes that the implementation
ignores every resume blob and unconditionally constructs an invalid task.
This is a native unsupported operation with native failure, not a successful
resumption that Diorama breaks. The absence of a protocol/creation callback
also prevents attaching an interceptor diagnostic at that point.

## Original investigation matrix — 2026-09-25

| Suite | macOS / iOS cases | Stable / snapshot Linux cases |
| --- | --- | --- |
| Original task rejection | 9 pass, 2 historical failures | 7 pass, 1 historical failure |
| Amended diagnostics/native refusal | 2 pass | 1 pass |
| Original response presentation | 4 pass | 1 pass, 3 failures |
| Initial constructors/delegate selection | 20 pass | 16 pass, 4 FN-07 failures |
| Native HTTP controls | 5 pass | 4 pass, 1 FN-07 failure |
| Extended constructors, async, schemes, resume | 25 pass | 23 pass |
| Controlled delivery/decisions | 14 pass | 7 pass, 6 FN-01 failures |
| Native/custom text buffering | 1 pass | 1 pass |
| Seeded cache | 16 pass | 16 pass |
| Optional methods/creation-hook proxy | 5 pass | Apple-only |
| Async delegate visibility | 4 pass | 2 pass, 4 FN-08 failures |
| Initial body forwarding/stream rejection | 16 pass | 16 pass |
| **Total per profile** | **123: 121 pass, 2 fail** | **113: 94 pass, 19 fail** |

The 26 newly added Apple cases and 28 newly added Linux cases all pass. The
full Apple matrix has four failed assertions in the two historical rejection
cases. Each Linux profile has 32 failed assertions across 19 cases: eight
FN-01 aggregation cases, five FN-07 assignment cases, four FN-08 visibility
cases, one original disposition case, and one original WebSocket case.

Both final Linux runs finish without a process crash. That result does not
resolve FN-10 or prove general quiescence. The final iOS upload-resume cases
pass after replacing the timed setup delay with the observed 104 callback.
Strict compilation succeeds on every profile. SwiftPM commands exit 1 and
xcodebuild exits 65 because the retained failing assertions remain enabled.
iOS reports zero skipped/expected failures and zero runtime warnings.
`scripts/lint` passes with zero violations in 106 files.

The original matrix retains historical assertions as executable evidence. Apple stream
and WebSocket tests that require protocol-only rejection and a custom error
predate the approved rejection amendment. Linux retains the analogous
WebSocket assertion and the original effective-disposition assertion. Their
newer policy-aligned controls run alongside them. Other failures reproduce
FN-01, FN-07, and FN-08. That run has no skipped or expected failures. The
merge-preparation policy below supersedes its test-gate treatment without
changing the recorded platform findings.

## Merge preparation and Linux repair policy — 2026-09-26

The owner directs implementation to proceed assuming the required
FoundationNetworking fixes will be made. Affected Linux URLSession behavior
is expected to remain broken until the runtime includes those repairs and
passes conformance. This does not affect the status of portable core,
persistence, or random behavior. FN-01 and FN-08 remain required repairs;
FN-05/FN-07 must be considered for full delegate interception. The
[handoff priority table](003-D02-foundationnetworking-handoff.md#owner-decisions-and-fix-priorities--2026-09-26)
records every finding as required, optional, avoidable, or still unclassified.
Task ownership remains the approved routing choice even with FN-03/FN-04 fixed.

The merge gate executes exact affected assertions inside Linux-only
`withKnownIssue` scopes: FN-01, FN-07, FN-08, and the historical disposition
comparison in D02; FN-03/FN-04 in D01. Unexpected passes fail so the expectations
must be reviewed when the runtime changes. All unrelated assertions, including
offline replay/rejection and task ownership, remain mandatory. No tests are
disabled. `DIORAMA_VERIFY_FOUNDATION_FIXES=1` runs without known-issue handling
for repair verification; use a focused filter for an individual fix.

The protocol-only rejection baseline now asserts the observed native stream
bypass and WebSocket error behavior. These replace superseded assertions that
contradicted the approved DD12 amendment. The separate creation-hook cancellation
and diagnostic tests still require zero connections and the native cancellation
error. Linux WebSocket refusal remains an ordinary passing native-boundary test.

The spike runs in the existing macOS, iOS, and Linux CI jobs through
`Spikes/URLSessionInterception/run swiftpm` or `Spikes/URLSessionInterception/run ios`.
It stays outside production targets and coverage. A green merge gate with known
issues is not evidence that those Linux capabilities work. D03–D05 and normal
review-unit approvals still apply; this PR does not start their work.

### Verified merge gate

The complete D01/D02 package runs on all four recorded profiles with Swift 6
strict concurrency and warnings as errors. Every command exits 0:

| Profile | Executed cases | Known failing assertions |
| --- | --- | --- |
| macOS 27, Apple Swift 6.4 | 138 (15 D01 + 123 D02) | 0 |
| iOS 27 Simulator, iOS 18 deployment target | 138 (15 D01 + 123 D02) | 0 |
| Stable Swift 6.4 Linux | 128 (15 D01 + 113 D02) | 37, across 20 cases |
| Pinned Swift 6.4.2 snapshot Linux | 128 (15 D01 + 113 D02) | 37, across 20 cases |

Linux's 37 known assertions comprise D01's seven FN-03/FN-04 assertions and
D02's 30: eight FN-01, fifteen FN-07, four FN-08, and three accepted
response-disposition assertions. All other assertions pass normally. Swift
Testing reports 40 test declarations on Apple and 36 on Linux; the table counts
their expanded parameter cases. Both Linux runs finish without a process crash;
FN-10 remains unresolved. Canonical `scripts/lint` passes with zero violations
in 109 files. Branch whitespace and local documentation links/anchors pass.

Local logs use `.build/d01-merge-*` and `.build/d02-merge-*`; iOS result bundles
are under `.build/urlsession-spike-ios/Logs/Test`. The new canonical commands
above also run in each PR's platform CI jobs. No FoundationNetworking patch or
production URLSession implementation is introduced by this update.

### Hosted CI follow-up

The first hosted Linux run reproduces FN-10; its successful backtrace identifies
the invalid-resume error path. The fixture now awaits session task enumeration
before resuming, ordering registration ahead of failure delivery. Both local
Linux matrices pass with that barrier, as do five focused snapshot repetitions
covering all four resume presentations. Hosted Linux also passes. The
[FN-10 diagnosis](003-D02-foundationnetworking-handoff.md#hosted-recurrence-and-registration-diagnosis--2026-09-26)
preserves the failed job and source analysis; broader lifecycle safety remains
D05 work.

The hosted iOS matrix exposes three-second observation watchdog expirations
across response, constructor, controlled-delivery, resume, and native HTTP
tests. The result summary identifies missing events at the deadline; later
field assertions in the original response test inspect an incomplete result.
The fixture watchdog and explicitly shortened request timeouts are now 30
seconds, returning promptly as soon as the required event is observed. These
are liveness bounds, not specified response-timing semantics. All body, error,
delegate, and zero-connection assertions remain mandatory; this adds no Apple
known issues or skipped tests. The iOS entry point now prints its xcresult
summary even when testing fails, preserving the original exit status and
making hosted assertion details available in the job log.

## Capability and implementation conclusions

| Surface | D02 conclusion | Remaining requirement |
| --- | --- | --- |
| Initial HTTP data tasks and in-memory body preparation | Native task families and body forms can be identified; private forwarding preserves tested wire bytes | Production preparation/matching integration; D03 redirect-specific rewriting |
| Unsupported task families and schemes | Intercepted upload/download/resume/body-stream/non-HTTP operations can be rejected before live access | Apply the boundary in each production attachment behavior |
| Apple stream/WebSocket tasks | Creation-hook cancellation plus an attributed diagnostic preserves native cancellation | Production proxy/reporter integration and D05 lifetime proof |
| Linux WebSocket and resume refusal | Tested runtime refuses before interception or live access | Preserve native failure; retest any runtime with different native capabilities |
| Aggregate versus segmented body delivery | Apple controls pass; Linux custom-protocol aggregates lose earlier chunks | FN-01 correction or separately proven solution |
| Response decisions | Apple gating/cancellation and explicit task cancellation pass; Linux ignored dispositions retain the accepted exception | Truthful recording validity and capability rejection under DD12/DD17 |
| Data-task conversion requests | An observing proxy can reject conversion with a custom error and no body | Proxy must actually receive the decision; FN-08 remains relevant |
| Caching | Seeded caches cannot bypass the tested interception configuration with effective request-policy normalization | Normalize both instrumented and private forwarding requests |
| Task delegates | Apple creation-hook wrapping and late-replacement rejection pass; Linux setter limitation is accepted | FN-08 needs resolution, considering FN-05/FN-07 together; no current Linux delegate conformance claim |
| Optional delegate methods | Apple can query tested optional selectors; equivalent Linux method-level detection is unproved | Operation-time enforcement and the explicit delegate capability boundary |
| Native execution and lifetime | Forwarding must avoid synchronous reentry; normal terminal cleanup must avoid redundant cancellation; the Linux invalid-resume control must await registration | D05 must investigate remaining FN-10 lifetime risks and prove quiescence before production depends on it |

These findings do not approve a production implementation. D03 still owns
redirect correlation; D04 owns authentication and ordinary HTTPS default
handling; D05 owns native lifecycle and the consolidated production breakdown.
No other review unit starts without owner instruction. Linux development
continues with FN-01/FN-08 carried as required conformance repairs, the accepted
native limitations retained, and FN-10 explicitly in the lifecycle audit.

## Reproduction and verification

Use the [recorded platform profiles](003-D02-task-rejection-and-response-presentation.md#environment-and-reproduction):
arm64 macOS 27 build `26A428`, Xcode 27 build `27A266a`, Apple Swift 6.4;
iPhone 17 Simulator on iOS 27 build `24A434`; x86_64 Ubuntu 24.04 with
`swift:6.4.0-noble`; and the pinned Swift 6.4.2 development snapshot below.
The Apple deployment target remains iOS 18/macOS 15. Compilation uses Swift 6
strict concurrency and warnings as errors.

From the repository root:

```sh
swift test --package-path Spikes/URLSessionInterception \
  --scratch-path .build/d02-spike -Xswiftc -warnings-as-errors --filter D02

container run --rm --arch x86_64 --cpus 2 --memory 4G \
  --mount type=bind,source="$PWD",target=/source,readonly --workdir /work \
  swift:6.4.0-noble \
  bash -lc 'cp -R /source/Spikes/URLSessionInterception /work/ && cd /work/URLSessionInterception && swift --version && SWIFT_BACKTRACE=enable=yes,interactive=no,threads=crashed swift test -Xswiftc -warnings-as-errors --filter D02'
```

For the snapshot substitute
`swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`.
The backtrace setting changes crash reporting only; the ordinary matrix does
not set `DIORAMA_D02_INLINE_FORWARDING`.

From `Spikes/URLSessionInterception`:

```sh
xcodebuild test -quiet -scheme URLSessionInterception-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  -derivedDataPath ../../.build/d02-ios-final-derived \
  -resultBundlePath ../../.build/d02-ios-verified-0925.xcresult \
  -only-testing:URLSessionInterceptionTests/D02BodyForwardingTests \
  -only-testing:URLSessionInterceptionTests/D02ExtendedRejectionTests \
  -only-testing:URLSessionInterceptionTests/D02ControlledDeliveryTests \
  -only-testing:URLSessionInterceptionTests/D02AsyncDelegateVisibilityTests \
  -only-testing:URLSessionInterceptionTests/D02CacheTests \
  -only-testing:URLSessionInterceptionTests/D02ConstructorTests \
  -only-testing:URLSessionInterceptionTests/D02DelegateBoundaryTests \
  -only-testing:URLSessionInterceptionTests/D02DiagnosticTests \
  -only-testing:URLSessionInterceptionTests/D02NativeHTTPTests \
  -only-testing:URLSessionInterceptionTests/D02ResponseTests \
  -only-testing:URLSessionInterceptionTests/D02TaskRejectionTests \
  -only-testing:URLSessionInterceptionTests/D02TextBufferingTests \
  -collect-test-diagnostics never \
  IPHONEOS_DEPLOYMENT_TARGET=18.0 SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
```

Use a fresh result-bundle path when repeating this historical iOS command.
The original local artifacts use `.build/d02-verified-*`; they are not committed.
That original V-doc review uses base `9a0a597e2aa67e49df1ac2f2306f438cbd172b56`.
Merge preparation instead compares the complete D02 branch, including its
review fixup, against the restacked `003-d01-urlprotocol-get-spike` branch.
The isolated experiments do not claim an upstream fix, production URLSession
conformance, or a complete native quiescence proof.
