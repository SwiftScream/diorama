# FoundationNetworking investigation handoff: D01 and D02

- Prepared: 2026-09-24, at the owner's request for a separate investigating agent.
- Owning unit: [003-D02](../plans/003-clean-slate-implementation.md#003-d02--task-rejection-and-response-presentation-spike).
- Evidence baseline: Diorama commit `8574f918c88566497b480eaaf86c05e2890307c7`
  on `003-d02-task-and-response-spike` in `SwiftScream/diorama`.
  Subsequent D02 commits add the owner decisions and FN-07 controls below.
- Upstream repository: [swiftlang/swift-corelibs-foundation](https://github.com/swiftlang/swift-corelibs-foundation).
- Inspected release: `swift-6.4.0-RELEASE`, commit
  `d29d01ba165f6957141e07ea7fe8144ab491bc24`.
- No upstream issue or PR has been filed, and no FoundationNetworking patch has
  been applied by this investigation. Current upstream issue/PR status has not
  been searched. This is a handoff of existing evidence, not a new platform
  capability decision.

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

The full spike intentionally contains retained failing evidence. A nonzero
exit is expected for the failing filters. Read the specific assertion rather
than treating every original failure as an unresolved product requirement.
No upstream patch has been tested against this baseline. The diagnostic probes
use a minimal test ledger; they do not import the production reporter.

Exact iOS commands, result counts, and remaining cases are in the
[D02 evidence](003-D02-task-rejection-and-response-presentation.md#environment-and-reproduction).
D01's earlier commands and source analysis are in the
[D01 evidence](003-D01-urlsession-interception.md). A read-only source checkout
used in this workspace is `/private/tmp/d01-foundation-6.4`; it is not a
committed dependency and may be absent in another workspace. Use the pinned
upstream revision for a reproducible fresh checkout.

## Plan boundary for the receiving investigator

On 2026-09-24 the owner directs Diorama to continue the plan and implementation
for Linux while FoundationNetworking fixes are investigated separately.
The [plan's Linux continuation policy](../plans/003-clean-slate-implementation.md#q1--urlprotocol-evidence-versus-production-task-division-resolved-by-owner-2026-09-06)
records that resolution of the development pause. Linux remains an intended
implementation target; segmented completion/async body delivery is broken
on the tested unpatched runtimes and cannot be advertised as conformant until
fixes or another separately reviewed solution pass the required evidence.
This is not a claim that all portable Diorama components are broken on Linux.

D02 remains in progress because its remaining matrix is untested. The owner
accepts FN-07 as a native limitation and resumes the remaining probes; there
is no requirement to wait for an upstream release. D03/D04 still follow
D02 review, and D05 still consolidates
the findings and confirms or revises the production task breakdown. Its review
must explicitly carry the Linux defects into implementation and conformance
work instead of treating them as passed capabilities. H/I implementation may
then proceed under that reviewed breakdown while the known upstream fixes are
pending. Normal review-unit approvals, required checks, and the prohibition on
live replay fallback remain in force; no failing assertion is suppressed by
this continuation decision.

FN-01 directly affects I02's aggregate results and I04's shared segmented
presentation. The body/persistence model and task-ownership choice remain
accepted. This update adds no upstream patch or production implementation and
does not mark D02 or the Linux conformance gate complete.
