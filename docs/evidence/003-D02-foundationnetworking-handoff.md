# FoundationNetworking investigation handoff: D01–D04

- Prepared: 2026-09-24, at the owner's request for a separate investigating agent.
- Owning unit: [003-D02](../plans/003-clean-slate-implementation.md#003-d02--task-rejection-and-response-presentation-spike).
- Evidence baseline: Diorama commit `8574f918c88566497b480eaaf86c05e2890307c7`
  on `003-d02-task-and-response-spike` in `SwiftScream/diorama`.
  Subsequent D02 commits add the owner decisions and FN-07–FN-10 observations below.
- D03 extension: The owner requests upstream findings during the approved
  redirect spike on 2026-09-26. [Redirect evidence](003-D03-redirect-correlation.md)
  adds FN-11–FN-14 and another FN-01 regression, based on D02 commit `7fb3558`.
- D04 extension: [Authentication evidence](003-D04-authentication-challenges.md)
  adds FN-15–FN-18, based on D03 commit `7cd15aa`. The owner approves preserving
  the native Digest limitation on 2026-09-26; this does not permit live replay.
- D05 checkpoint: [Native lifetime evidence](003-D05-native-quiescence.md)
  identifies a Diorama contract conflict around use after session invalidation.
  It does not add an upstream repair requirement; see the distinction below.
- Upstream repository: [swiftlang/swift-corelibs-foundation](https://github.com/swiftlang/swift-corelibs-foundation).
- Inspected release: `swift-6.4.0-RELEASE`, commit
  `d29d01ba165f6957141e07ea7fe8144ab491bc24`.
- This investigation does not apply FoundationNetworking patches or file
  upstream issues/PRs. On 2026-09-26 the owner reports local FN-03/FN-04 fixes
  and begins upstream contribution work separately. Those patches have not
  been tested by this branch; upstream issue/PR status has not been rechecked.

## Summary and priority

FN-01 is **issue 1** from the latest D02 report. The identifiers below are local
handoff identifiers, not upstream issue numbers.

| ID | Finding | Classification | Effect on Diorama |
| --- | --- | --- | --- |
| FN-01 | Custom-protocol completion/async responses retain only the last data chunk | Reproduced defect; source explains it | Blocks correct aggregate results for segmented responses. |
| FN-03 | `URLProtocol` request properties disappear during request bridging/copying | Reproduced defect candidate with a concrete copy omission | Original forwarding marker fails; an isolated private-session control works. |
| FN-04 | Configuration `httpAdditionalHeaders` are absent at custom interception | Reproduced parity difference; whether this violates the API contract remains open | Original routing method fails; task ownership is now the approved replacement. |
| FN-05 | `URLSessionTaskDelegate.didCreateTask` hook is absent | Confirmed API gap | Apple's early rejection mechanism is unavailable on this Linux implementation. |
| FN-06 | WebSockets fail before custom interception when libcurl lacks support | Tested runtime limitation; accepted native failure | Not a current Diorama blocker on these profiles. |
| FN-07 | Assigning `task.delegate` before resume does not select that delegate for callbacks | Reproduced native/custom-protocol defect; source explains it | The property setter cannot provide equivalent task-specific delegation on these Linux profiles. |
| FN-08 | An async-supplied delegate is not reflected in `task.delegate` | Reproduced native/custom-protocol visibility defect; source explains it | A working delegate callback path is hidden from the tested adapter guard; combined with FN-05, proxy installation/rejection is unproven. |
| FN-09 | Synchronously creating a forwarding task inside `startLoading` traps in libdispatch | Reproduced on stable Linux; shared queue reentry explains it | Forwarding task creation and teardown need an independent executor; this does not require changing the native-session boundary. |
| FN-10 | Task behavior lookup traps while registration or teardown is incomplete | Local crash plus hosted snapshot recurrence; the hosted stack identifies the invalid-resume error path | The resume fixture orders registration before resume; D05 still audits native lifetime. |
| FN-11 | Custom-protocol redirect notification traps | Reproduced fatal error in the URLProtocol client | Required repair for live interception and replay redirects. |
| FN-12 | Path-relative redirect resolves against the origin root | Reproduced native HTTP defect; source explains it | Native proposal is already incorrect before Diorama observes it. |
| FN-13 | 307/308 redirects discard the outgoing body | Reproduced native HTTP defect; source explains it | Native request and wire bytes disagree; retest private-hop forwarding after FN-11 is repaired. |
| FN-14 | Explicit Authorization survives a cross-host redirect | Reproduced native HTTP security-sensitive difference from Apple | The native proposal already contains the header; recommend upstream credential-handling review. |
| FN-15 | Accepting a custom authentication challenge replaces the protocol with native HTTP | Reproduced interception defect; source explains it | Required repair: an offline Basic replay can make a real request. |
| FN-16 | Native Digest challenges are not presented; the Digest retry handler is unimplemented | Reproduced native limitation plus source evidence | Owner-approved native exception; optional upstream capability work. |
| FN-17 | A configured HTTP/HTTPS proxy is not reached | Reproduced native configuration gap; source does not consume the property | Recommend upstream native proxy support; no additional interception failure is established. |
| FN-18 | Certificate rejection maps to `URLError.unknown` | Reproduced native error-mapping gap; source has no TLS-specific case | Nice to have; Diorama can preserve the native domain/code. |

FN-01 blocks correct aggregate results for segmented Linux responses. On
2026-09-24 the owner directs continued planning and implementation for Linux
while upstream defects are investigated separately; see the
[continuation boundary](#plan-boundary-for-the-receiving-investigator).
FN-03 is a focused candidate for upstream correction. FN-04 needs contract
investigation before calling it an upstream bug. FN-05/FN-06 provide context
for rejection behavior; they are not requests to add WebSocket support to
Diorama.
FN-07 is another focused upstream candidate. It differs from the working
`data(for:delegate:)` result path and reproduces without Diorama interception.
The owner accepts FN-07 as a native limitation with no required upstream fix.
FN-08 exposes a further issue with that working async path: its actual
delegate cannot be identified through the public getter. On 2026-09-25 the
owner records it as an issue that needs addressing and authorizes the remaining
D02 work. It is a required delegate-integration repair, not an accepted native
limitation that Diorama may silently inherit.
FN-09 is an implementation constraint with a queue-isolation approach, tracked
separately from FN-08's unresolved delegate visibility. See its reproduction
and the final matrix below before depending on the workaround.
D03 adds FN-11 as a required custom-redirect repair. FN-12–FN-14 are native
HTTP findings recommended for upstream work; their separate
[priority discussion](#d03-fix-priorities--2026-09-26) preserves the owner's
distinction between interception requirements and inherited native defects.

## Owner decisions and fix priorities — 2026-09-26

Proceed with the planned Linux adapter on the assumption that the required
FoundationNetworking fixes will be made. Affected Linux URLSession behavior
is expected to remain broken until those fixes are present in the runtime and
verified. Implementation and merge preparation need not wait for an upstream
release. Passing checks with known issues is not a Linux conformance claim.

| ID | Upstream priority for Diorama | Decision and implementation consequence |
| --- | --- | --- |
| FN-01 | **Required** | Correct segmented completion/async aggregation. No simple workaround preserves the intended delivery semantics. Prioritize this repair first. |
| FN-08 | **Required** | Make the working explicit async delegate path observable for faithful interception or reliable rejection. A getter-only fix does not establish full proxy support. |
| FN-05 | **Required capability for full delegate interception; repair mechanism to investigate** | FN-08's full proxy solution needs a supported pre-resume hook, such as the missing creation callback or an equivalent. The hook is not independently required for the currently accepted native unsupported-task refusals. |
| FN-07 | **Nice to have as a standalone fix; conditionally part of FN-08** | Preserve the accepted native limitation for consumer property assignment. If proxy installation uses that property, dispatch must honor the proxy, including async behavior variants. Investigate this with FN-05/FN-08. |
| FN-03 | **Not essential: simple avoidance** | Exclude Diorama's protocol from the private forwarding session; no forwarding property is needed. Fixing property preservation remains useful upstream. The owner reports a local fix. |
| FN-04 | **Not essential: simple avoidance** | Task ownership removes the routing-header dependency and remains the production choice. The owner reports a local header fix; its intended API contract still belongs in upstream review. |
| FN-06 | **Not essential: accepted native refusal** | Preserve the tested offline WebSocket error. Diorama does not require Linux WebSocket support. Recheck exclusion enforcement if a future runtime supports it. |
| FN-09 | **Not essential if the demonstrated workaround passes lifecycle conformance** | Create and tear down forwarding tasks on an independent owned serial executor. The D02 fixture works; D05 still proves races and lifetime. |
| FN-10 | **Fixture workaround for the identified path; broader impact remains unclassified** | Hosted CI identifies invalid-resume error delivery racing registration. The fixture waits for session enumeration before resume. Upstream should correct native queue/registration ordering; D05 still determines whether supported Diorama operations need a repair. |

The former FN-02 response-disposition issue remains removed from the requested
upstream work. Its repair is optional under DD12/DD17. Private forwarding uses
immediate `.allow` and explicit task cancellation; recording validity and
rejection of incompatible replay remain required.

At the D02 review, FN-01 and FN-08 are the required repairs; D03 adds FN-11
below. These are not an exhaustive promise about later findings.
Review FN-08 with FN-05/FN-07 as one delegate-integration
problem. Correct getter identity may enable rejection; full support additionally
requires early proxy installation and coherent callback dispatch.

Task ownership remains approved even if FN-03/FN-04 are fixed. It derives the
route from the actual session, avoids caller-header overrides and private HTTP
metadata, and already works on tested stock runtimes. D03/D05 still need to
validate redirects, asynchronous lookup races, and lifetime. Add patched-runtime
results to the evidence when tested without replacing the original results.

### Executable known issues

Merge preparation retains the intended assertions in Linux-only
`withKnownIssue` scopes for FN-01, FN-03, FN-04, FN-07, FN-08, and the historical
response-disposition comparison. Unrelated assertions, all task-ownership
checks, and offline rejection guarantees remain mandatory. Superseded
protocol-only stream/WebSocket expectations now assert the accepted native
baseline; creation-hook cancellation and diagnostic tests still prove the
adapter's required exclusion behavior.

An unexpected pass fails the gate so repaired runtimes cannot silently retain
stale expectations. Set `DIORAMA_VERIFY_FOUNDATION_FIXES=1` when running
`Spikes/URLSessionInterception/run swiftpm` on a patched build to check the
original assertions directly. Optional unfixed defects still fail in that mode;
use a focused `swift test --filter` when verifying an individual repair.
No tests are disabled by D01/D02 merge preparation. D03 separately disables
the FN-11 crash paths on stock Linux, with restoration controls below.
FN-09's inline forwarding and
FN-10's unguarded resume remain explicitly opt-in crash investigations;
FN-10 has no known-issue suppression.

## D05 lifecycle checkpoint: native invalidation is not a new Linux repair

The [D05 lifetime probe](003-D05-native-quiescence.md) exposes a conflict in
Diorama's escaped-session promise. A raw native session cannot create new
tasks after invalidation: the tested macOS call raises `NSGenericException`,
and FoundationNetworking's data-task factory explicitly traps at
[`Session invalidated`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSession.swift#L573-L583).
The interceptor never gets the opportunity to return Diorama's promised
recoverable infrastructure error. Leaving the session open also fails to
establish the tested Apple native cleanup boundary.

This is documented native API use outside its lifetime, not an additional
interception defect or a prerequisite upstream repair. No FN-19 is assigned.
The owner resolves the checkpoint by approving native session invalidation:
the returned session is usable only during scenario execution, and creating
new tasks afterward crashes. DD12/DD17 record the amendment. D05 continues
its remaining lifecycle experiments before establishing the full boundary. Existing FN-01, FN-08, FN-11, and FN-15 priorities
are unchanged; the remaining FN-09/FN-10 lifecycle investigation is still open.

## Why Diorama encounters these paths

Diorama plans to return an adapter-owned native `URLSession` whose copied
configuration installs a per-session custom `URLProtocol`. Replay presents
heads and body segments through `URLProtocolClient`; Foundation then supplies
delegate, completion-handler, or async presentation. Record and passthrough
use private live forwarding machinery. The spike package exercises Foundation
directly and imports no production Diorama code.

The approved routing method identifies a protocol's native task by object
identity in adapter-owned sessions' outstanding-task lists. The owning active
lease identifies the execution. It requires no HTTP routing field. This choice
does not repair Foundation's response buffering.

The FN-01 response probes exercise the **custom `URLProtocolClient` path**.
Ordinary libcurl HTTP completion handlers use a separate body accumulator.
The later [native HTTP controls](003-D02-task-rejection-and-response-presentation.md#native-response-disposition-baseline)
exercise delegate disposition and task-delegate selection without a custom
protocol; they do not replace FN-01's aggregate-consumer probes.

## FN-01 — Earlier response chunks are lost for completion and async consumers

### Reproduction and observed result

The [response probe](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02ResponseTests.swift)
uses an ephemeral session with caching disabled and a custom protocol that
emits:

1. HTTP status 203, `Content-Length: 12`, and `X-D02: chunks`;
2. `didLoad(Data("first-".utf8))`;
3. `didLoad(Data("second".utf8))`;
4. `urlProtocolDidFinishLoading`.

These calls occur consecutively in `startLoading`. Each chunk contains only
new bytes. A loopback listener detects any unintended native connection.

| Consumer | Apple Foundation | Both tested Linux profiles |
| --- | --- | --- |
| `dataTask(with: URL)` with data delegate | `first-second`; one coalesced 12-byte callback | `first-second`; two 6-byte callbacks |
| `dataTask(with: URL, completionHandler:)` | `first-second` | **Only `second`, with no error** |
| Async `data(from:)` | `first-second` | **Only `second`, with no error** |

All forms retain status 203 and the custom response header. No connection is
accepted. The exact-body expectation fails only for the two aggregate Linux
presentations. URLRequest and task-delegate overloads have not yet been probed
for this defect. Apple chunk coalescing here does not prove fidelity for
separately timed chunks.

### Source diagnosis

Apple's [`urlProtocol(_:didLoad:)` documentation](https://developer.apple.com/documentation/foundation/urlprotocolclient/urlprotocol%28_%3Adidload%3A%29)
requires each delivery to contain only newly loaded data since the preceding
invocation. The upstream
[`URLProtocolClient` declaration](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLProtocol.swift)
documents the same incremental contract and explicitly excludes cumulative
deliveries. A single whole-body call is valid, but repeated incremental calls
are also valid. This defect does not depend on Diorama's forwarding machinery:
the direct custom-protocol probe already reproduces it.

- [`URLSessionTask.swift:1314–1335`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L1314-L1335):
  `_ProtocolClient.urlProtocol(_:didLoad:)` assigns each incoming chunk to
  `protocol.properties[.responseData]`, overwriting the previous value. The
  delegate branch separately forwards each chunk.
- [Lines 1201–1206](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L1201-L1206):
  the completion branch returns that stored value.
- [`URLSession.swift:761–775`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSession.swift#L761-L775):
  `data(from:)` builds on completion-handler behavior, explaining its identical
  failure.
- [`NativeProtocol.swift:266–292`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/NativeProtocol.swift#L266-L292):
  the built-in protocol's in-memory completion path emits an accumulated body
  in a single client call. This is a different path that must retain correct
  behavior when repairing the custom-protocol accumulator.

### Why ordinary Linux HTTP can still receive complete bodies

The built-in path does not require the network to deliver one chunk. Its
[`didReceive(data:)`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/NativeProtocol.swift#L96-L145)
processes successive buffers, forwards them directly to data delegates, and
appends them to the selected body drain. For completion-handler tasks,
[`createTransferBodyDataDrain()`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/NativeProtocol.swift#L346-L369)
selects in-memory accumulation;
[`byAppending(bodyData:)`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/TransferState.swift#L172-L186)
appends each buffer. Only after that accumulation does `completeTask()` send
one complete body to the protocol client. Delegate tasks instead forward
successive buffers without that accumulation. These are source findings, not
a new native-server experiment.

A recording containing exactly one body segment avoids FN-01's overwrite.
Linux origin does not guarantee one segment: a recorder using a data delegate
on its private forwarding session can observe multiple buffers even when its
outer caller uses completion or async presentation. Consequently Linux-to-Linux
replay can also encounter FN-01. A recording captured exclusively from an
aggregate completion result would have one observed body delivery, but would
not preserve incremental timing. The production forwarding implementation
has not yet been built or tested.

An upstream fix should investigate accumulation and completion lifetime, with
regressions for zero/one/many chunks, binary data, delegate delivery, async
conveniences, cancellation/error cleanup, and the existing built-in protocol
path. These are suggested follow-up checks, not completed evidence. No claim
is made that replacing one assignment alone is a sufficient reviewed fix.

### Repair options and other built-in protocols

The recommended first upstream change is a focused correction to the client's
aggregation for completion/async consumers. Existing native aggregation need
not be removed to make custom protocols correct:

```text
Built-in HTTP:  [ABCDE]         -> client accumulation -> ABCDE
Custom protocol: [A][B][C][D][E] -> client accumulation -> ABCDE
```

HTTP submits its already accumulated body once, so accepting it as one input
does not duplicate its bytes. The implementation should accumulate only where
an aggregate result is required, preserve incremental delegate delivery, avoid
unnecessary full-body retention for delegate tasks, and handle response/retry
boundaries and terminal cleanup. In particular, successive authentication
attempts must not be concatenated into one response. This is a repair proposal,
not an implemented or validated upstream patch.

The release contains these built-in protocol implementations:

| Implementation | Body handling |
| --- | --- |
| HTTP/HTTPS, `_HTTPURLProtocol` | Uses shared `_NativeProtocol` aggregation for completion-handler data tasks; delegate data is delivered incrementally. |
| FTP, `_FTPURLProtocol` | Inherits the same `_NativeProtocol` aggregation machinery. |
| `data:` URLs, `_DataURLProtocol` | Decodes the complete embedded payload and sends one `didLoad` call. |
| WebSocket, `_WebSocketURLProtocol` | Inherits HTTP setup but overrides received-data handling to queue messages on the WebSocket task; it does not aggregate the connection into a single response body. Availability depends on libcurl support. |

Source: [shared native drain selection](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/NativeProtocol.swift#L346-L369),
[FTP inheritance](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/FTP/FTPURLProtocol.swift#L18),
[data URL delivery](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/DataURLProtocol.swift#L85-L92),
and [WebSocket message handling](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/WebSocket/WebSocketURLProtocol.swift#L102-L181).

A later refactoring could move HTTP/FTP completion aggregation entirely into
the client. That change must remove the native final whole-body emission,
reconcile existing direct delegate callbacks to prevent duplicate delivery,
and preserve download file output, caching, and response/retry boundaries.
HTTP also retains a redirect body until the follow/refuse decision; that
[protocol-specific buffering](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/HTTP/HTTPURLProtocol.swift#L705-L726)
has a separate purpose. Centralizing data-task presentation is a broader
cleanup, not a prerequisite for correcting FN-01. Keeping it separate gives
upstream maintainers a smaller correctness change to review and consider for
backporting.

### Diorama impact

Our stable model already stores the complete body once plus segment metadata.
The failure occurs when those segments are delivered to native consumers.
Segmented replay can return truncated bytes to completion and async callers.
Record/passthrough would have the same exposure if their forwarding path emits
separate chunks through this client; that is an implication for the planned
adapter, not an executed nested-forwarding result.

Sending the complete body once would avoid this particular reproducer but
would change incremental delegate delivery and timing. Repeatedly sending
cumulative bodies would duplicate bytes for delegates. Neither is an approved
general workaround. The shared body schema, matching, persistence, and
task-ownership route do not need to change to fix the demonstrated defect.

## FN-03 — Forwarding request property is lost during bridging

The D01 test `URLProtocol property bypasses the interceptor when forwarding`
in [InterceptionTests.swift](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/InterceptionTests.swift)
marks an `NSMutableURLRequest` with `URLProtocol.setProperty`, then bridges it
to `URLRequest` for the session. Apple retains the private marker; Linux loses
it and re-enters the interceptor.

This smaller probe reproduces loss before a session exists:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let request = NSMutableURLRequest(url: URL(string: "http://example.invalid")!)
URLProtocol.setProperty(true, forKey: "probe", in: request)
print(URLProtocol.property(forKey: "probe", in: request as URLRequest) as Any)
// Tested Apple: Optional(1). Tested Linux: nil.
```

Source path:

- [`URLProtocol.swift:323–339`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLProtocol.swift#L323-L339)
  stores and retrieves `protocolProperties`.
- [`URLRequest.swift:45–46`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLRequest.swift#L45-L46)
  bridges using `mutableCopy()`; the public bridge entry points are at
  [lines 286–302](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLRequest.swift#L286-L302).
- [`NSURLRequest.swift:149–170`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/NSURLRequest.swift#L149-L170)
  copies request fields but omits `protocolProperties`.

The owner considers this a likely oversight and a legitimate upstream bug.
Investigate copy, mutable-copy, and Swift bridge preservation, including
independence after mutation. A private forwarding session with the interceptor
omitted passes the D01 control on all tested platforms. That control prepares
the forwarded request outside `startLoading`; it does not prove full nested
forwarding, callback relay, cancellation, or finalization.

## FN-04 — Session additional headers are unavailable at interception

D01's `two instrumented sessions route independently` supplies an internal
route in `URLSessionConfiguration.httpAdditionalHeaders`. The custom protocol
receives it on Apple and does not receive it on Linux. Explicit headers on the
request are visible on both. The ordinary built-in Linux HTTP handler may
still transmit the configured headers; this is not evidence of omission from
outgoing built-in HTTP requests.

The release source applies
[configuration to the request](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSession.swift#L538-L540),
but [Configuration.swift:107–125](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/Configuration.swift#L107-L125)
only adds cookies there. Custom protocol selection happens at
[`URLSessionTask.swift:129–167`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L129-L167).
Additional headers are merged later in the built-in
[`HTTPURLProtocol.swift:361–390`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/HTTP/HTTPURLProtocol.swift#L361-L390).

Whether custom protocols are contractually entitled to observe those headers
at that stage remains a research question. Apple/Linux parity alone does not
settle it. Header precedence, case-insensitive names, and avoiding duplicate
merges need attention if changing the configuration stage. The observed
request-header override of the old route was another reason to abandon that
routing scheme. Task ownership is the approved production choice, so this
finding no longer determines Diorama's routing architecture.

D01 inspected the corresponding request-copy and header paths on upstream
`main` as of 2026-09-23 and found the same behavior in source. This handoff does
not assert that today's upstream head or issue tracker has been rechecked.

## FN-05 — No task-creation delegate hook

The inspected release's
[`URLSessionTaskDelegate`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionDelegate.swift)
has no `urlSession(_:didCreateTask:)` requirement. A method with that spelling
on the test delegate is never called on either tested Linux profile. This
removes the synchronous pre-return interception point used on Apple to cancel
unsupported tasks before caller or diagnostic-sink reentry.

The D02 [rejection fixtures](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02RejectionFixtures.swift)
record task-creation callbacks; Linux produces none. The absence itself does
not prove every unsupported operation escapes: upload/download controls still
reach `URLProtocol.startLoading`, and unsupported WebSockets fail natively.
Resume/conversion forms still need separate evidence. Adding this callback is
an API/ordering investigation, not a preapproved Diorama workaround.

## FN-06 — Native WebSocket refusal with this libcurl build

Both tested Linux profiles lack libcurl WebSocket support. In
[`URLSessionTask.swift:939–957`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L939-L957),
`URLSessionWebSocketTask.resume()` fails with `URLError.unsupportedURL`
(`NSURLErrorDomain/-1002`) before calling the superclass or selecting a custom
protocol. The [diagnostic probe](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02DiagnosticTests.swift)
confirms no creation callback, no custom interception result, no connection,
and the native error through task completion and WebSocket receive.

The owner explicitly accepts this native failure on the tested unsupported
profiles. Diorama does not need a manufactured diagnostic or replacement error
before a callback exists. This is not a blanket assertion that all Linux
builds lack WebSocket support. A profile enabling it needs fresh rejection
evidence. Linux stream-task creation is separately marked unavailable in
[`URLSession.swift:511–514`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSession.swift#L511-L514).

## FN-07 — Assigning task.delegate does not select the callback recipient

### Reproduction and result

The [constructor matrix](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02ConstructorTests.swift)
creates a session with one delegate, then creates a data task without a
completion handler and assigns a second delegate before resuming:

```swift
let task = session.dataTask(with: request)
task.delegate = taskDelegate
// The getter returns taskDelegate on every tested platform.
task.resume()
```

On Apple, the assigned task delegate receives the response, body, and
completion. On both Linux profiles, these callbacks instead reach the session
delegate. The task delegate receives no response or completion. All four body
forms reproduce the same dispatch result; a single-chunk test response arrives
intact, and no connection reaches the loopback fallback listener.

The [native HTTP control](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02NativeHTTPTests.swift)
repeats this with an ordinary session and a real loopback HTTP response, with
no custom protocol installed. It observes the same platform difference. Thus
the dispatch defect is inherited from FoundationNetworking rather than caused
by the interceptor or task-ownership routing.

An explicit delegate passed to async `data(for:delegate:)` follows a different
path: the Linux constructor probe invokes its response callback and returns
the expected aggregate result. This finding must not be generalized to all
task-specific delegate APIs. No redirect or challenge callback equivalence is
claimed for either form by these response probes.

### Source diagnosis and repair direction

At the pinned Swift 6.4 release source:

- [`URLSessionTask.swift:102–114`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L102-L114)
  stores the assigned delegate in `_taskDelegate`, and its getter returns that
  value before falling back to the session delegate. The setter forbids
  assignment after resume; this probe assigns before resume.
- [`URLSession.swift:663–682`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSession.swift#L663-L682)
  selects the **session** delegate for `.callDelegate`, without consulting the
  task's assigned delegate. Its separate completion-with-task-delegate cases
  use the delegate stored with that behavior instead.
- Both the [native HTTP response path](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/HTTP/HTTPURLProtocol.swift#L515-L546)
  and [custom protocol response path](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L1080-L1089)
  use this behavior selection, consistent with the two reproductions.

A focused repair should investigate honoring the explicit task delegate while
retaining session fallback. Check native/custom data delivery, completion and
async constructors, no session delegate, reassignment before resume, error
delivery, and redirect/challenge delegation. Those are suggested regressions,
not completed upstream repair evidence. No source patch has been made here.

### Diorama impact and review status

A Linux caller relying on the property setter already receives callbacks on
the wrong delegate with native FoundationNetworking. Intercepted requests have
the same exposure, which can bypass a consumer's intended response or other
task-specific policy. Preserving complete bytes alone does not prove correct
delegation. This defect does not invalidate task-ownership routing.

The owner accepts this native limitation and directs continued D02 work.
An upstream fix is optional for Diorama. Task ownership does not depend on
the setter, and private forwarding can use the working session delegate.
The adapter must preserve effective native callback selection rather than
trusting the task delegate getter alone. Keep the working async delegate form
distinct and do not advertise equivalent property-assigned delegation on an
unfixed runtime. This finding does not block D02 or require a new architecture.

## FN-08 — Async delegate parameters are not visible through task.delegate

### Reproduction and observed result

The [visibility probes](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02AsyncDelegateVisibilityTests.swift)
create a session delegate labeled `session`, then pass a different delegate
labeled `task` to either `data(from:delegate:)` or `data(for:delegate:)`.
No assignment to the task's delegate property is performed.

| Observation | Apple Foundation | Both Linux profiles |
| --- | --- | --- |
| Custom protocol inspects `task.delegate`, explicit async delegate supplied | `task` | **`session`** |
| Same custom protocol, no explicit async delegate | `nil` | `session` |
| Linux supplied delegate's response callback inspects `dataTask.delegate` | Apple aggregate convenience does not invoke that response callback in this fixture | **`session`, although `task` is receiving the callback** |
| Ordinary native Linux HTTP repeats that callback inspection | Linux-specific control | **Same incorrect getter identity** |

Bodies arrive intact in this single-chunk custom control and the native HTTP
control. The custom-protocol cases make no native connection. Four Apple cases
pass; Linux has six cases, with the two supplied-delegate custom cases and two
native cases failing their delegate-identity assertions. The original run
retains ordinary failures; merge preparation keeps these same assertions in
Linux-only known-issue scopes under the policy above.

### Source diagnosis

In release commit `d29d01ba165f6957141e07ea7fe8144ab491bc24`:

- [`data(for:delegate:)` and `data(from:delegate:)`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSession.swift#L735-L775)
  put the supplied delegate into `.dataCompletionHandlerWithTaskDelegate`.
- The [private task factory](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSession.swift#L574-L585)
  creates the task and registers that behavior without assigning the delegate
  to the task's `_taskDelegate` field.
- The [public getter](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L102-L114)
  therefore falls back to the session delegate, while
  [callback dispatch](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSession.swift#L663-L682)
  uses the separately stored async delegate.

This is related to FN-07's disconnected property/dispatch paths but has a
different consequence: a delegate that does work is hidden by the getter.
The same getter also participates in protocol-extension fallback logic, so
upstream should inspect callback fallback as well as identity. That fallback
impact is a source-based investigation question, not a completed reproducer.

### Diorama impact and repair questions

The planned session-level proxy cannot observe a callback dispatched directly
to this supplied delegate. A protocol-time guard sees the same delegate value
with and without the async parameter, so the tested getter-based guard cannot
reject or validate the hidden path. FN-05 also removes Apple's pre-resume
creation hook. The setter cannot be used after resume and, as FN-07 shows,
does not reliably control dispatch before resume either.

Consequently accepting a native live outcome is insufficient evidence that
Diorama can record its decisions, diagnose an unrepresentable disposition,
or enforce the required decision boundary. This does not make the native async
request itself fail. It is an additional integration gap for a working native
callback path, with a stronger Diorama impact than FN-07 alone.

Investigate keeping the async parameter, public task property, and behavior
dispatch consistent across constructors. A corrected getter could permit
reliable rejection of an unsupported explicit delegate at protocol loading.
Full proxy support also needs a supported pre-resume interception hook and
dispatch that honors the installed proxy. Review this together with FN-05 and
FN-07 rather than fixing only `.callDelegate` dispatch. Regression candidates
include explicit/nil async delegates, session fallback, public getter identity,
delegate replacement before resume, and response/redirect/challenge callbacks.
No upstream patch is implemented or claimed sufficient here.

On 2026-09-25 the owner resolves this review checkpoint: FN-08 needs
addressing, and D02 continues its remaining isolated experiments. Resolution
must establish reliable detection/rejection or faithful interception of the
explicit async delegate path, with regression evidence; a getter-only patch
is not assumed to provide full proxy support. This requirement remains open
until a repair or separately reviewed solution passes conformance.

The [extended evidence](003-D02-delivery-and-delegate-boundaries.md) records the
successful Apple hook controls and other completed probes. An upstream release
is not a prerequisite to continuing D02 under Q1. The current Linux callback
surface cannot be advertised as conformant, and continued implementation does
not waive the required repair.

## FN-09 — Synchronous forwarding reentry traps on the shared session queue

### Reproduction and source diagnosis

The initial body-forwarding fixture calls another session's
`dataTask(with:).resume()` directly inside `URLProtocol.startLoading`.
On stable Swift 6.4 Linux, the first intercepted case terminates the process
with signal 4 in `__DISPATCH_WAIT_FOR_QUEUE__` / `_dispatch_sync_f_slow`.
The same fixture works on Apple. Isolating the Linux body suite reproduces
the trap independently of the async-rejection and response suites.

The inspected release explains the dependency cycle:

- [`resume()` schedules `startLoading` on the task work queue](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L471-L488).
- [Each session's work queue targets one shared serial queue](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSession.swift#L220-L254).
- [Creating a new task synchronously enters the new session's work queue](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSession.swift#L560-L585).

That synchronous call waits for the serial target already executing the outer
protocol callback. Task resume/cancel and session invalidation also contain
synchronous queue entry points, so an implementation must examine teardown as
well as task creation. The observed trap and source diagnosis establish a
platform reentry hazard; this handoff does not assert a documented universal
guarantee that every URLSession API is callable synchronously from that callback.

### Diorama handling and reproduction

The final [body-forwarding fixture](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D02BodyForwardingTests.swift)
enqueues forwarding creation and cancellation on an owned serial queue that
does not target FoundationNetworking's internal queue. It returns from
`startLoading` without waiting. Start/stop jobs share that queue; an already
processed stop prevents a later start. The existing test-only synchronized
client-delivery wrapper relays responses. This introduces no additional unsafe
sendability or production dependency.

The final matrix and limits are in the
[D02 completion evidence](003-D02-completion-and-capability-matrix.md).
D05 still owns a full proof of cancellation races, callback quiescence, and
forwarding-tail lifetime. Task ownership remains the routing method. An
upstream repair is not required if the isolated execution approach passes
production conformance; this is a different resolution from accepting missed
callbacks or changed bytes.

The fixture retains an explicit process-crash reproducer. Inside the Linux
spike directory, run it separately from the normal matrix:

```sh
DIORAMA_D02_INLINE_FORWARDING=1 \
  SWIFT_BACKTRACE=enable=yes,interactive=no,threads=crashed \
  swift test -Xswiftc -warnings-as-errors --filter D02BodyForwardingTests
```

Expect process termination on the tested stable Linux release. The environment
switch only selects inline task creation for this experiment. Normal tests
exercise the isolated queue; no assertion is skipped or marked expected.
`threads=crashed` also avoids an unrelated crash of the Swift backtrace helper
while enumerating threads under this container environment.

## FN-10 — Task-registry lookup trap during the concurrent matrix

### Hosted recurrence and registration diagnosis — 2026-09-26

The first [D02 hosted Linux job](https://github.com/SwiftScream/diorama/actions/runs/36219227231/job/108341191719)
also traps on the pinned snapshot. This time the backtrace succeeds:

```text
URLSession.behaviour(for:)
_ProtocolClient.urlProtocol(task:didFailWithError:)
closure #1 in closure #1 in closure #1 in URLSessionTask.resume()
```

The immediately preceding test starts the `nativeDelegate` invalid-resume
control. The inspected release source provides a concrete registration race:

- [`invalidDownloadTask`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSession.swift#L623-L635)
  constructs a task with the public default initializer, then queues registry
  insertion asynchronously on the session work queue.
- [The default initializer](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L248-L276)
  gives that task an independent queue; ordinary tasks instead target the
  session queue. An immediate `resume()` can therefore report unsupported URL
  and look up behavior before registration finishes. The registry may be
  **not yet populated**, rather than already cleared.

The fixture now awaits a `getAllTasks` completion before `resume()`. The lookup
is queued after registration, so its completion supplies an observable ordering
barrier without sleeping. Its returned list is not used: this Linux method
filters out never-resumed tasks. Existing completed-state observation before
teardown remains. This workaround changes the native unsupported-resume
control, not Diorama's production routing or cancellation contract.

Set `DIORAMA_D02_UNSAFE_RESUME=1` and run the Linux
`D02ExtendedRejectionTests.*resume` filter to restore immediate resume for
investigation. The race is scheduling-dependent; the switch is not a guaranteed
crash reproducer. Upstream should investigate initialization, registration, and
registry-queue confinement together. The stack/source diagnosis does not prove
every earlier crash shares this cause, nor establish general callback quiescence.
D05 retains that audit. Current Linux merging need not suppress the whole
matrix or claim that FoundationNetworking itself is repaired.

### Original local observation — 2026-09-25

One stable Swift 6.4 run of the full `--filter D02` matrix terminates with:

```text
FoundationNetworking/TaskRegistry.swift:118:
Fatal error: Trying to access a behaviour for a task that in not in the registry.
```

The concurrent log includes body forwarding and invalid-resume completion at
that point. The stack backtracer itself then fails, so the exact caller of the
registry lookup is not identified. The snapshot run of the same revision
finishes. No deterministic standalone reproducer or upstream patch is claimed.

The [native completion paths](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L1189-L1217)
invoke consumer completion before setting task state to completed and scheduling
registry removal. Meanwhile [cancellation](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L381-L410)
schedules further protocol/error work. A completion/teardown race is a plausible
source-based explanation, not a proven attribution of this crash. Investigation
should identify every late lookup and its registry-lifetime assumptions.

The final body fixture marks private completion before forwarding the terminal
callback and uses graceful invalidation for an already completed forwarder.
It also separates async return bytes from delegate observations; mixing those
two fixture collectors had produced a spurious doubled-body assertion. The
Linux invalid-resume control now observes `task.state == .completed` before
teardown. These changes prevent avoidable fixture races; a subsequent passing
run is not proof that the native registry race is repaired.

Keep this observation in D05's lifecycle audit. Diorama must establish owned
callback quiescence and safe forwarding-tail release, and should not recancel
work already reported terminal. This concern is distinct from the accepted
ignored response-disposition behavior, whose upstream repair remains optional
and which has not been restored as an issue in this handoff.

The initial local artifact is `.build/d02-complete-linux-stable.log` (not
committed); the final matrix is documented in
[D02 completion evidence](003-D02-completion-and-capability-matrix.md).

## Related Apple observations

These are context for the cross-platform design, not FoundationNetworking
defects:

- Stream tasks bypass `URLProtocol` and can connect. The synchronous creation
  callback can cancel them first.
- WebSockets reach the custom protocol, but a supplied test error domain is
  rewritten to `NSURLErrorDomain`, and its custom marker is lost.
- The approved Apple policy cancels excluded stream/WebSocket tasks before
  invoking consumer callbacks, records an attributed diagnostic, and preserves
  native cancellation errors. The diagnostic/reentrant-sink probes pass on
  macOS and iOS; no live connection occurs.
- Back-to-back response chunks coalesce into one data-delegate callback in the
  minimal probe. Separately timed chunk fidelity remains untested.
- The initial task's original request retains absent, empty, in-memory, and
  streamed body distinctions even when the protocol/current request represents
  in-memory data as a stream. This provides an initial-request classification
  path; redirect-derived bodies still need D03 evidence.

The authoritative amendments are [task-ownership routing](../design-decisions/12-urlsession-scope.md#task-ownership-routing-amendment--2026-09-24)
and [native rejection errors](../design-decisions/12-urlsession-scope.md#native-rejection-errors-amendment--2026-09-24).

## Environments and running the evidence

All runs use Swift 6 language mode, strict concurrency, and warnings as errors.
The isolated package has no third-party dependencies. It targets macOS 15 and
iOS 18; observed Apple runs are on the newer runtimes below.

| Profile | Exact environment |
| --- | --- |
| macOS | arm64 macOS 27.0 `26A428`; Xcode 27.0 `27A266a`; Apple Swift 6.4 `swiftlang-6.4.0.34.1`, clang `2100.3.34.1` |
| iOS | iPhone 17 Simulator, iOS 27.0 `24A434`, same Xcode |
| Stable Linux | x86_64 Ubuntu 24.04, `swift:6.4.0-noble`; Swift `6.4 (swift-6.4-RELEASE)` |
| Snapshot Linux | x86_64 Ubuntu 24.04, `swiftlang/swift`; Swift `6.4.2-dev (LLVM 15622a86b1749a9, Swift d2e983b81b18217)` |

Both Linux images report `libcurl4-openssl-dev:amd64 8.5.0-2ubuntu10.13`.
Stable OCI index digest:
`sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9`;
selected amd64 image:
`sha256:3fd7537e088df14007e5c9dd71a1b4d91b19067df727b17294ae0f6ea79f6423`.
Pinned snapshot:
`swiftlang/swift@sha256:15ae709b1d8eb1f8691b300f5721499d007e944694f2c0e9929a55580c9bf1a5`.

Run FN-01's body aggregation cases from the repository root on macOS:

```sh
swift test --package-path Spikes/URLSessionInterception \
  --scratch-path .build/d02-spike -Xswiftc -warnings-as-errors \
  --filter 'D02ResponseTests.*two'
```

Using Apple Container from the repository root:

```sh
container run --rm --arch x86_64 --cpus 2 --memory 4G \
  --mount type=bind,source="$PWD",target=/source,readonly --workdir /work \
  swift:6.4.0-noble \
  bash -lc 'cp -R /source/Spikes/URLSessionInterception /work/ && cd /work/URLSessionInterception && swift --version && dpkg-query -W libcurl4-openssl-dev && swift test -Xswiftc -warnings-as-errors --filter "D02ResponseTests.*two"'
```

Substitute the snapshot image above for the second Linux profile. The same
SwiftPM test command works inside a Linux development environment without
Apple Container. The complete historical follow-up commands remain in the
D02 evidence linked below.

| Filter | Relevant evidence and expected baseline |
| --- | --- |
| `D02ResponseTests.*two` | FN-01: three parameter cases; Apple 3 pass, Linux 1 pass/2 fail in the recorded baseline. |
| `D02DiagnosticTests` | Apple diagnostic/reentry: two cases pass; Linux native WebSocket refusal: one case passes. |
| `InterceptionTests` | Original D01: ten tests; Apple 10 pass, Linux 8 pass/2 fail (headers and forwarding property). |
| `TaskOwnershipTests` | Five routing tests pass on all tested profiles. |
| `D02TaskRejectionTests` | Original pre-amendment assertions: Apple 9 pass/2 fail; Linux 7 pass/1 fail. These historical custom-error assertions do not assess the approved rejection policy. |
| `D02ConstructorTests` | Initial body forms and delegate selection: Apple 20 pass; Linux 16 pass/4 fail, with only property-assigned task delegation failing. |
| `D02NativeHTTPTests.*delegate` | FN-07 native HTTP control: Apple 1 pass; Linux 1 fail, independent of custom interception. |
| `D02AsyncDelegateVisibilityTests` | FN-08: Apple 4 pass; Linux 2 pass/4 fail, including two native HTTP controls. |
| `D02ControlledDeliveryTests` | Timed aggregate results retain FN-01: Apple 14 pass; Linux 7 pass/6 fail. Conversion stream API is Apple-only. |
| `D02BodyForwardingTests` | Sixteen cases pass on each final profile using isolated forwarding. Set `DIORAMA_D02_INLINE_FORWARDING=1` separately to reproduce FN-09 on stable Linux. |
| `D02ExtendedRejectionTests` | Final task/async/scheme/resume matrix: Apple 25 pass; Linux 23 pass. |

The table records the original failing evidence. The current merge gate keeps
documented Linux defects executable as known issues and expects a zero exit.
Prefix a focused command with `DIORAMA_VERIFY_FOUNDATION_FIXES=1` to restore
ordinary failures when investigating or validating an upstream repair. Read
the specific assertion rather than treating every original failure as an
unresolved product requirement.
No upstream patch has been tested against this baseline. The diagnostic probes
use a minimal test ledger; they do not import the production reporter.

Exact iOS commands, result counts, and remaining cases are in the
[D02 evidence](003-D02-task-rejection-and-response-presentation.md#environment-and-reproduction).
D01's earlier commands and source analysis are in the
[D01 evidence](003-D01-urlsession-interception.md). A read-only source checkout
used in this workspace is `/private/tmp/d01-foundation-6.4`; it is not a
committed dependency and may be absent in another workspace. Use the pinned
upstream revision for a reproducible fresh checkout.

## D03 fix priorities — 2026-09-26

The owner authorizes D03 and asks to add upstream issues to this document.
These priorities apply the existing continuation policy; they do not amend
DD12/DD17 or assert that a patched runtime has passed conformance.

| ID | Upstream priority for Diorama | Rationale |
| --- | --- | --- |
| FN-11 | **Required** | The public custom redirect callback crashes, although ordinary HTTP redirects work. Both intercepted forwarding and replay require this path. No simple workaround preserves the accepted native URLSession decision boundary. |
| FN-01 extension | **Existing required repair** | Native refused redirect bodies expose the same replacement behavior. Include this regression when moving aggregation into the client. Private data delegates receive the body. |
| FN-12 | **Recommended upstream; native limitation rather than a new interception requirement** | A plain URLSession already chooses the wrong relative destination. Preserve and diagnose native behavior; do not add a second redirect-policy implementation inside Diorama. Correct portable target semantics require a repaired runtime. |
| FN-13 | **Recommended upstream; private-hop workaround remains to verify on Linux** | Plain URLSession loses a body that its own proposal still contains. Apple's isolated per-hop forwarding preserves the body. FN-11 currently prevents testing the same Linux path; do not claim that workaround proved. |
| FN-14 | **Strongly recommended upstream for credential handling; native limitation** | Plain URLSession sends the synthetic Authorization value to another host. This is not introduced by Diorama. Repair upstream rather than silently inventing a live credential policy in the adapter. |

FN-12–FN-14 fit the owner's distinction between an interception defect and
behavior already incorrect in native Foundation. They remain visible in
capability evidence and upstream work. They are not additional reasons to stop
Linux implementation pending a release. FN-14 deserves upstream review even
though it is not a Diorama-specific compatibility blocker.

## FN-11 — Custom-protocol redirect notification traps

### Reproduction and observed result

The [D03 custom redirect tests](../../Spikes/URLSessionInterception/Tests/URLSessionInterceptionTests/D03RedirectTests.swift)
create an ordinary ephemeral URLSession with a custom URLProtocol. It presents
a 302 response and proposed request through
`client.urlProtocol(_:wasRedirectedTo:redirectResponse:)`.

Apple follows or invokes the native redirect delegate, depending on consumer
policy. Stable Swift 6.4 Linux traps at `URLSessionTask.swift:1403`, before any
decision can occur. The backtrace contains the `_ProtocolClient` witness for
the redirect callback, called by the fixture's synchronized delivery wrapper.
The pinned CI snapshot reproduces the same fatal callback in a standalone
minimal protocol. No Diorama production code is involved.

The exact inspected implementation is an unconditional `fatalError` in
[`_ProtocolClient`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L1402).
Native HTTP works through
[`_HTTPURLProtocol.redirectFor`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/HTTP/HTTPURLProtocol.swift#L453),
which invokes delegates and starts another transfer without using that generic
client callback. Consequently, ordinary networking success does not cover the
custom-protocol surface required by Diorama.

### Impact, repair scope, and verification

Keep request derivation in the HTTP protocol where appropriate, but implement
the generic client's redirect transition and delegate decision. Review native
task/current-request updates, protocol selection/recreation, pending decisions,
refusal-body delivery, limits, cancellation, and callback ordering together.
Avoid independent redirect chains in the forwarding task and outer task.
The Apple experiments demonstrate that task ownership can retain one group
through this transition without HTTP correlation metadata.

Presenting only the final response would discard required redirect decisions.
Directly calling the consumer delegate and emulating the entire native
redirect lifecycle would require a separate architecture review; it is not a
simple workaround for the approved boundary.

The 45 replay/forwarding cases in `D03RedirectTests` (eight test declarations)
are disabled only on stock Linux because execution terminates the process.
After an upstream repair, run the original assertions with:

```sh
DIORAMA_VERIFY_FOUNDATION_FIXES=1 swift test \
  --package-path Spikes/URLSessionInterception \
  --scratch-path .build/urlsession-spike -Xswiftc -warnings-as-errors \
  --filter D03RedirectTests
```

`DIORAMA_D03_UNSAFE_REDIRECT=1` also enables the suite for an intentional crash
reproduction in an isolated process. Do not enable either flag on an
unpatched runtime in the ordinary shared test job. Remove the disable condition
when supported repaired runtimes pass the assertions. The native D03 controls
continue running on Linux.

## FN-01 extension — Native refused redirect body is overwritten

D03's ordinary completion task receives a 302 response with a seven-byte body
and a delegate returns `nil` to refuse the redirect. Apple returns the body;
both Linux profiles return empty Data with no error. An otherwise equivalent
data-delegate control receives the seven bytes on Linux.

[`_NativeProtocol.didReceive(data:)`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/NativeProtocol.swift#L107)
collects redirect bytes in `lastRedirectBody`, bypassing the normal body drain.
On refusal,
[`didCompleteRedirectCallback`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/HTTP/HTTPURLProtocol.swift#L718)
emits those bytes with `didLoad`, then `completeTask()` emits the empty
in-memory drain with another `didLoad`. FN-01's client replaces the first
payload with the empty one. This is a native HTTP manifestation of the same
aggregation design, not a new cancellation issue.

Include refusal bodies in FN-01's aggregation migration/regression tests.
Simply appending in the client can repair this path, but native protocols that
emit accumulated data still need the previously discussed audit to avoid
duplicating bytes. Diorama's private data delegate receives these bytes and is
not blocked by this particular aggregate-consumer path.

## FN-12 — Path-relative redirects resolve at the wrong directory

The native D03 control requests `/directory/start`. Its 302 response contains
`Location: next`. Apple proposes and sends `/directory/next`; stable Linux
and the snapshot propose and send `/next`. Root-relative redirects and the
tested absolute targets work.

[`redirectRequest(for:fromRequest:)`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/HTTP/HTTPURLProtocol.swift#L552)
replaces the path with `"/" + targetURL.path` when the target has no leading
slash. It does not resolve a relative reference against the current request
directory. Use standard URL reference resolution and add regressions for
directory-relative, parent, query-only, fragment, root-relative, and network-path
references; only the directory-relative failure is demonstrated here.

This changes the actual live target before any Diorama preparation. It is a
native HTTP bug, so an upstream repair is desirable for all consumers.
Reimplementing target selection inside Diorama would alter native policy and
is not adopted. The exact target assertion remains a Linux known issue.

## FN-13 — Native 307/308 redirects discard request bodies

A seven-byte POST followed through 307 or 308 sends POST with zero body bytes
on both Linux profiles. This occurs with automatic following and explicit
session-delegate following. The delegate's proposed request still has the
seven-byte `httpBody`. Apple retains seven bytes on the second wire request.
The tested 301/302/303 bodyless-GET rewriting passes on both platforms.

Both automatic
[`redirectFor`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/HTTP/HTTPURLProtocol.swift#L496)
and delegate
[`didCompleteRedirectCallback`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/HTTP/HTTPURLProtocol.swift#L713)
set `task.knownBody = .none` before starting the next transfer.
[`URLSessionTask.getBody`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L218)
then uses that known empty body. Recompute the effective body from the accepted
redirect request, while preserving the correct method/body rewriting rules.
Include delegate-replaced bodies and repeated redirects in upstream tests.

This is already incorrect in native URLSession. Diorama's tested Apple
forwarder creates a new private task for the next effective request, with
explicit body context, and preserves the bytes. FN-11 prevents the equivalent
Linux proof; do not depend on that as a verified Linux workaround yet.

## FN-14 — Explicit Authorization survives a cross-host redirect

The native control supplies only a synthetic test credential, then redirects
from `127.0.0.1` to `localhost` on a second loopback listener. On Apple the
proposed request and second wire request omit Authorization. Both Linux
profiles retain and send it. An unrelated public header survives on both.
An explicitly supplied Cookie header also survives on both platforms; do not
generalize Apple's Authorization behavior to all credential fields.

The same
[`redirectRequest(for:fromRequest:)`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/HTTP/HTTPURLProtocol.swift#L552)
copies the request and replaces its URL without filtering this header when
the host changes. The observed result is a security-sensitive native behavior
difference, regardless of whether it is treated as a strict API contract bug.
Review explicit Authorization handling alongside origin changes, URL
credentials, credential storage, and transport downgrades. Those other cases
have not been tested by D03; this finding concerns one explicitly supplied
header over loopback HTTP and does not claim a general authentication audit.

Diorama encounters the already prepared native proposal. DD12 defers
cross-origin construction to Foundation plus Diorama's preparation rules; this
spike adds no separate live credential policy. Upstream correction is strongly
recommended, with a narrow known issue preserving the expected wire assertion.

## D04 fix priorities — 2026-09-26

| ID | Priority | Decision and consequence |
| --- | --- | --- |
| FN-15 | **Required** | Custom challenge answers must preserve the protocol boundary. Accepting a replay credential must never start native HTTP. Continue planned implementation while the upstream repair is outstanding, without advertising conformance. |
| FN-16 | **Not essential; native capability improvement** | The owner explicitly approves preserving the native Digest limitation. Exclude unsupported Digest handling from the Linux capability profile and reject incompatible replay during setup. An upstream implementation would enable future support after conformance. |
| FN-17 | **Recommended native fix; not an additional interception prerequisite** | The configured native proxy path already fails without Diorama. Preserve the observed native outcome; do not claim working proxy authentication on this runtime. Proxy replay still requires the FN-15 correction and capability evidence. |
| FN-18 | **Nice to have** | Improve the native error mapping. Default trust validation still rejects the certificate; Diorama preserves the existing unknown code under DD12's typed failure contract. |

### FN-15 — Custom challenge decisions bypass their sender and start HTTP

Reproduced on stable Swift 6.4 Linux and the pinned D04 snapshot with a
synthetic Basic challenge issued by
`URLProtocolClient.urlProtocol(_:didReceive:)`. The ordinary URLSession task
delegate answers `.useCredential` through its completion handler. Instead of
returning to the supplied custom sender, FoundationNetworking makes one real
HTTP request to the request URL and returns its response:

```text
challenges=1, sender=0, liveRequests=1, bodyBytes=24
```

The controlled loopback response is `unexpected-live-response`; the custom
protocol's intended body is `authorized`. No external destination or real
credential is used. The executable case is
`custom credential choice must return to the sender without live networking`
in `D04LinuxChallengeTests.swift`. Three narrowly scoped known assertions
retain the intended sender, network, and response requirements. Set
`DIORAMA_VERIFY_FOUNDATION_FIXES=1` and filter that exact test name to verify a
full sender repair without enabling unrelated unsafe experiments.

Source at the pinned `swift-6.4.0-RELEASE` commit:

- [`URLSessionTask.swift`, `_ProtocolClient.didReceive challenge`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L1247):
  `proceed(using:)` suspends the task, applies the HTTP authentication handler,
  replaces its protocol with `_HTTPURLProtocol`, then resumes. It does not
  dispatch the credential decision to the custom challenge sender.
- The same method handles default behavior by directly completing the task
  when it has no usable proposed credential. Reject falls through to task
  cancellation. These source paths also need sender/continuation review; the
  minimal Linux runtime reproduction above focuses on `.useCredential`.

This differs from ordinary native Basic authentication, whose challenge/retry
path works in the control. It is an interception defect affecting replay and
private-session forwarding, not permission to inherit an already broken live
operation. Keeping the original protocol and routing its answer back through
an appropriate continuation is essential. Native `_HTTPURLProtocol` retries
must continue working when the client/HTTP responsibilities are separated.

The minimum Diorama requirement is to preserve the custom protocol and its
pending continuation when the consumer answers, without starting HTTP or
prematurely completing its task. Automatic sender dispatch is a natural full
URLProtocol repair, but the demonstrated delegate-completion bridge can provide
the decision path without it, as on Apple. The raw sender reproducer describes
the fuller API expectation. If a repair deliberately provides Apple-like
sender behavior, verify Diorama with the delegate-bridge replay/forwarding
cases; its failure of that raw sender assertion alone does not prove Diorama
is still blocked. No live request is acceptable in either approach.
Coordinate the repair with FN-01's client-versus-protocol division of work and
FN-08's delegate dispatch boundary. Do not replace it with a Diorama live retry,
hand-written HTTP authentication, or a replay network fallback.

Apple also fails the tested automatic sender round trip, but its native task
stays offline. An explicit delegate completion observer successfully drives
both a synthetic continuation and a private native request. D04 tests that
bridge separately; it does not compensate for Linux replacing the protocol
inside the native completion handler.

### FN-16 — Native Digest authentication is unimplemented

The native HTTP control sends a valid Digest challenge with realm, fixed nonce,
MD5, and `qop="auth"`. On stable Linux, all five consumer modes (use, default,
reject, cancel, repeated failure) receive the 401 body, with no task-level
challenge and no retry. Apple presents the challenge and invokes native Digest
retry behavior. The fixture checks header presence and lifecycle; it does not
implement or validate the cryptographic Digest response.

Source explains the native result:

- [`HTTPMessage.swift`, challenge parser](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/HTTP/HTTPMessage.swift#L138)
  explicitly accepts only Basic. The Digest challenge is not presented.
- [`URLSessionTask.swift`, `digestAuth`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionTask.swift#L1427)
  is an unconditional `fatalError`. This is source evidence, not a claim that
  the native HTTP control reaches the trap. A custom Digest challenge can
  reach this separate path; stock Linux replay must not attempt it.

On 2026-09-26 the owner selects: “Preserve the native Digest limitation;
document a narrow platform exception.” See the matching
[DD12 amendment](../design-decisions/12-urlsession-scope.md#foundationnetworking-digest-exception--2026-09-26)
and [DD17 amendment](../design-decisions/17-http-lifecycle-composition.md#foundationnetworking-digest-exception--2026-09-26).
Do not fabricate a challenge for the native 401. Upstream Digest support is
optional for otherwise working Linux operations. FN-15 remains required for
custom Basic handling and the no-live-replay invariant.

### FN-17 — Configured HTTP and HTTPS proxies are not reached

The D04 fixture configures `connectionProxyDictionary` with HTTP/HTTPS enable,
proxy host, and proxy port keys, and uses a reserved `.invalid` origin. A local
proxy supplies the entire exchange; it never opens an origin connection. Apple
reaches it, receives an HTTP 407, and, for HTTPS CONNECT, presents a task-level
Basic or Digest challenge with the associated 407 response. Accepting that
challenge causes a credential-bearing CONNECT retry. The proxy then sends a
deliberate 502 to prove a failure continuation without a TLS tunnel.

Stable Linux and the pinned snapshot make zero requests to the configured proxy, presents no challenge,
and fails the native operation. This uses an uninstrumented URLSession; it is
not caused by Diorama's forwarding or routing. A source search of the pinned
release finds `connectionProxyDictionary` declared and copied in
[`URLSessionConfiguration.swift`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/URLSessionConfiguration.swift),
and copied into the internal `URLSession/Configuration.swift` value,
but no use by the transport. This supports the inference that these settings
are not implemented on this profile.

Further source context, not additional runtime claims: `_ProtocolClient` only
synthesizes authentication for status 401; `URLProtectionSpace.create` reads
WWW-Authenticate and builds an origin protection space. Merely routing through
a proxy may therefore expose further 407 work. The spike has not investigated
libcurl environment-variable proxy configuration or implemented a substitute
proxy stack. Upstream should verify those paths independently.

Reproduction: filter `native proxy authentication presents a response owned
challenge` in the D04 suite. Linux uses four native cases (Basic/Digest ×
HTTP/HTTPS) with precise known assertions for the missing proxy behavior;
Apple additionally runs the private-forwarding variants. Origin-access guards
stay unconditional. The native Digest exception remains separate from this
configuration finding; fixing proxy routing does not implement Digest.

The upstream recommendation is to implement the native configuration/407 path.
Unlike FN-15, this fixture establishes no additional failure introduced by
interception. Until it works, the capability matrix must not advertise native
Linux proxy authentication. Do not substitute an origin 407 response for a
real configured proxy experiment.

### FN-18 — Certificate rejection loses its specific URL error code

The opt-in HTTPS control succeeds against `https://example.com/` and rejects
`https://self-signed.badssl.com/` using default native validation. On stable
Linux and the pinned snapshot, both native and privately forwarded failures report
`NSURLErrorDomain/-1` (`URLError.unknown`). Apple reports `-1202`
(`serverCertificateUntrusted`). No trust bypass or custom acceptance is used.

[`MultiHandle.swift`, `urlErrorCode(for:)`](https://github.com/swiftlang/swift-corelibs-foundation/blob/d29d01ba165f6957141e07ea7fe8144ab491bc24/Sources/FoundationNetworking/URLSession/libcurl/MultiHandle.swift#L359)
has no certificate-validation-specific case; unmapped libcurl failures become
`NSURLErrorUnknown`. The receiving investigator should add appropriate mappings
with certificate and connection-level controls. This is a native fidelity
improvement, not a Diorama blocker: DD12 preserves domain/code, including unknown
codes, and the tested validation still fails. Do not parse native description
text into a replacement production error code.

Reproduce by setting `DIORAMA_D04_HTTPS=1` and filtering
`ordinary HTTPS uses native default trust handling`. These external endpoints
are not part of the default deterministic gate. The probe asserts the native
error and an in-memory Boolean indicating a certificate-related description;
it does not persist or print the description. A changed mapping needs fresh
baseline evidence; no known-issue scope suppresses trust acceptance.

## Plan boundary for the receiving investigator

On 2026-09-24 the owner directs Diorama to continue the plan and implementation
for Linux while FoundationNetworking fixes are investigated separately.
The [plan's Linux continuation policy](../plans/003-clean-slate-implementation.md#q1--urlprotocol-evidence-versus-production-task-division-resolved-by-owner-2026-09-06)
records that resolution of the development pause. Linux remains an intended
implementation target; segmented completion/async body delivery is broken
on the tested unpatched runtimes and cannot be advertised as conformant until
fixes or another separately reviewed solution pass the required evidence.
This is not a claim that all portable Diorama components are broken on Linux.

D02 is complete as an isolated investigation on 2026-09-25; the
[final matrix](003-D02-completion-and-capability-matrix.md) retains all native
defect assertions. The owner accepts FN-07 as a native limitation and
resumes the remaining probes; those probes subsequently expose FN-08's hidden
working delegate path. On 2026-09-25 the owner records FN-08 as requiring
resolution and resumes D02. There is no requirement to wait for an upstream
release before completing the remaining isolated evidence. Those experiments now
finish, with FN-09's executor constraint and FN-10's lifecycle observation
carried forward. On 2026-09-26 the owner authorizes D03 while D01/D02 remain
under review. Its [completed investigation](003-D03-redirect-correlation.md)
adds FN-11 as a required redirect-client repair and FN-12–FN-14 as native HTTP
findings. The owner subsequently authorizes D04 and approves its native Digest
exception. D04 adds required FN-15, optional native FN-16–FN-18, and the tested
Apple delegate-completion bridge. D05 still consolidates these findings and
confirms or revises the production task breakdown. Its review
must explicitly carry the Linux defects into implementation and conformance
work instead of treating them as passed capabilities. H/I implementation may
then proceed under that reviewed breakdown while the known upstream fixes are
pending. Normal review-unit approvals, required checks, and the prohibition on
live replay fallback remain in force. The owner's 2026-09-26 merge policy above
supersedes the original requirement to leave all defect assertions as ordinary
failures: documented Linux assertions now use explicit known-issue scopes.

FN-01 directly affects I02's aggregate results and I04's shared segmented
presentation. The body/persistence model and task-ownership choice remain
accepted. FN-08 additionally requires a delegate-integration solution before
claiming that capability. FN-11 blocks generic redirect presentation for both
record/passthrough and replay. FN-15 additionally blocks custom authentication
without a native HTTP escape. The Digest exception does not relax that boundary.
This update adds no upstream patch or production implementation. Completing the investigation does not pass the Linux
conformance gate or D05's lifecycle review.
