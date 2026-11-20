# HTTP message values and schema components

`DioramaHTTP` is an optional portable product. It uses `HTTPTypes` for in-memory
heads and owns its message/body Codable shapes. Core has no HTTP dependency.
These are components of the future version-one HTTP system payload, not a
standalone scenario envelope or a registered HTTP system. System version dispatch
and full lifecycle validation arrive in H13. No wire HTTP version is inferred.

## Building values

```swift
import DioramaHTTP
import HTTPTypes

let request = try HTTPRequestMessage(
    head: HTTPRequest(
        method: .post, scheme: "https", authority: "example.invalid", path: "/items"),
    body: .bytes([0, 128, 255]))
let response = HTTPResponseHead(head: HTTPResponse(status: .ok))
let content = HTTPResponseBody.resource(
    try HTTPBodyResource(path: "bodies/items.bin"))
```

Message and body values are immutable, Sendable, and Hashable. Heads retain HTTP
Types equality semantics (including case-insensitive field names and status-code equality).
Codecs additionally preserve original field-name spelling and reason phrases.
Bodies belong to `HTTPResponseNode`'s body lifecycle, rather than `HTTPResponseHead`.
`HTTPRequestBody` cannot express unavailable content; `HTTPResponseBody` can.
Resource construction never accesses the filesystem. Repository loading resolves
resources into owned bytes; file publication and containment are described in
[resource storage](persistence-schema-v1.md#document-and-resource-files). Inline versus resource storage does not change logical byte semantics.

## Resource ownership

`HTTPBodyResource(path:bytes:)` requires `PreparedValue<[UInt8]>` and retains the
exact prepared bytes. Use the system's selected preparation policy before this
initializer. Every `HTTPBodyResource` owns bytes, including valid empty content;
there is no path-only initializer or unresolved runtime case. `bytes()` returns
those immutable owned bytes without throwing or performing I/O.

Repository decoding eagerly resolves resources and retains bytes in the returned
HTTP values. Callers exclude publication and manual edits of the same
scenario until decoding and resource resolution finish. File fixtures use ordinary
`name.json` and sibling `name-resources/` paths; no published symlinks or random
generation directories are required. It does not rerun normalization, redaction, or placement policy.
A loaded definition remains usable after replacement or removal of its source.
A newly recorded definition owns its bytes before publication starts, so failed
encoding, staging, commit, or staging cleanup cannot delete its only backing
content. No filesystem handles, resolver closures, adapters, or execution state
are retained by an HTTP resource. This initial implementation uses memory
proportional to referenced content; lazy or spooled ownership remains deferred.

Component encoders persist resource paths; `JSONScenarioCodec.encode` returns
complete JSON and resource bytes. Resource-backed HTTP decoding requires a
resource-resolution context and fails with `ScenarioResourceError.unavailable`
when none is supplied or referenced bytes cannot be read. Plain `JSONDecoder`
and byte-only `JSONScenarioCodec.decode` therefore cannot decode resource-backed
HTTP values without a context. Inline and absent/unavailable bodies retain
standalone decoding. `JSONScenarioRepository` supplies the context to registered
system codecs. HTTP's `Codable` boundary extracts the existing
`ScenarioDocumentSnapshot` with `ScenarioResourceCoding.resolutionContext(from:)`
and passes that explicit context into persisted-to-runtime body conversion.
The persisted shape is validated before resolving a reference, and each resource
is resolved once per body conversion. A test-only registered consumer proves this
path with actual HTTP body values; production URLSession registration remains
its own unit.

## Owned Codable shapes

Requests contain required `method`, `fields`, and `body`, with optional `scheme`,
`authority`, and `path`. Omitted target components remain nil; explicit null is
rejected. Targets retain their text, including escapes, query order, case, and
empty components. The codec validates HTTP field characters before constructing
currency values, avoiding their repairing initializers. It does not impose a
URLSession-specific URL grammar. Extended CONNECT protocol pseudo-fields are
rejected explicitly; arbitrary UTF-8 target text is supported, while non-UTF-8
pseudo-field bytes are rejected instead of being repaired.

Response heads contain required integer `status`, string `reasonPhrase`, and
`fields`. The currency type's full `0...999` status range is retained without
classifying unusual codes as transport failures. No HTTP/1.1 default is stored.

`fields` is an ordered array of objects with required `name` and `value`.
Values are literal strings except for the explicit derived Content-Length form
described below.
Names must be valid regular field names; pseudo-fields and invalid tokens are
rejected. Repeated names, including Set-Cookie, remain separate entries. Field
values use a byte-preserving ISO Latin-1 scalar mapping: each scalar U+0000 through
U+00FF denotes its corresponding byte. Disallowed HTTP control bytes and scalars
above U+00FF are rejected. ASCII remains readable; UTF-8 non-ASCII field bytes
appear as their Latin-1 equivalents and reconstruct exactly. No dependency
Codable or header dictionary defines the file contract. Compression indexing
hints are transport metadata and are not persisted.

Bodies have exactly one of these shapes:

```json
{"kind":"absent"}
{"kind":"bytes","text":""}
{"kind":"bytes","text":"<html>Hello</html>\n"}
{"kind":"bytes","base64":"AID/"}
{"kind":"resource","resource":"bodies/items.bin"}
{"kind":"unavailable"}
```

The last case is response-only. Inline bytes have exactly one of `text` or
`base64`. The canonical writer uses text when strict UTF-8 decoding and re-encoding
reproduce the original bytes exactly, including empty content. JSON escaping does
not alter the recovered bytes. BOMs, CRLF, Unicode spelling, JSON whitespace,
duplicate JSON names, number spellings, and escapes are preserved. JSON bodies are
text, never embedded structured objects. No transcoding, normalization, newline
conversion, or lossy UTF-8 repair occurs.

Other bytes use a standard, padded base64 string with no whitespace or line
breaks. Readers reject invalid characters, missing or extra padding, and nonzero
unused padding bits. Valid base64 input is accepted for any bytes; canonical
writing selects text if those bytes qualify. Binary-looking controls in otherwise
valid UTF-8 are escaped by JSON without data loss. Readers reject simultaneous
text/base64, explicit null, non-string content, and content on another body kind.

The in-memory `.bytes([UInt8])` API retains exact bytes; text and base64 are only
persisted representations. Numeric byte arrays are not accepted in this unreleased
schema. A resource path is a nonempty slash-separated relative path. Empty,
dot, dot-dot, and NUL-containing components are rejected. Spaces, Unicode, and
other literal filename characters are accepted; filesystem-specific naming and
length limits fail during I/O. Percent escapes are never decoded or normalized.
Publication rejects case aliases (including directory aliases) and file/directory
prefix collisions. These follow the shared
[resource path contract](persistence-schema-v1.md#document-and-resource-files).

All objects reject unknown keys, missing required fields, explicit nulls,
unknown body tags, and fields incompatible with the selected body case. The
canonical JSON transport follows the existing repository convention: sorted
object keys, pretty printing, unescaped slashes, semantic array order, and one
trailing newline. The component Codable conformances do not configure encoders.
Canonical request and response fixtures live in `Tests/DioramaHTTPTests/Fixtures`.

Preparation/redaction and matching have their own policies described below.
Native conversion remains a separate plan unit. Message builders do not perform those operations or
authorize persisting unprepared secrets.

## Strict lifecycle components

`HTTPInteraction<Failure>` owns one `initialRequest` and one `result`. The
adapter supplies a Sendable stable `Failure` type; the shared HTTP domain defines
no universal transport failure taxonomy. Lifecycle values are immutable and
Sendable, with conditional Equatable and Codable conformances when the failure
type supports them. They contain semantic observations, without executing native
callbacks or deciding whether a test passes.

The attempt result is exactly one case:

- `.received(HTTPResponseNode)` introduces one timed response head and one
  response-owned body, redirect, authentication, or disposition continuation.
- `.failed(HTTPTimed<Failure>)` represents failure before any head.
- `.openAtRecordingHorizon` explicitly preserves work still awaiting a head or
  failure when observation ends.

`HTTPBodyDelivery` owns exactly one `content` value and one `conclusion`. Returned
content is complete. Failed and open content is only the prefix actually observed;
neither conclusion invents later bytes. All existing content cases remain distinct:
absent, present bytes (including empty), resource, and unavailable. Unavailable
means that the adapter could not expose the content, rather than that it observed
zero bytes. Resource construction validates a path without resolving its content.
The lifecycle records what was exposed; native replay capabilities and resource
availability require separate system admission.

The body conclusion is exactly one of `.returned(HTTPBodyCompletion)`,
`.failed(HTTPTimed<Failure>)`, or `.openAtRecordingHorizon`. Successful message
delivery can have any representable HTTP status, including 4xx/5xx. A transport
failure after a head remains a body failure, independent of that status. Open
work has no completion delay or synthesized failure; later replay must preserve
pending behavior until ordinary cancellation or execution cleanup.

Only `HTTPBodyCompletion` can contain optional `HTTPTrailers`. Trailer fields use
the same literal ordered-field representation and validation as message fields,
including repeated names and exact byte values. Their delay precedes the trailer
delivery; completion has a separate delay after the trailers. Omitted trailers
differ from present empty trailer fields. Explicit null is rejected.

`HTTPDelay(milliseconds:)` accepts Core's `OverridableValue<Int64>` and rejects a
negative effective delay. `HTTPTimed(after:value:)` takes an already validated
delay. A response head's delay starts at invocation or completion of the preceding
redirect decision; failure before a head uses the same attempt-local anchor.
A body conclusion's delay starts at its delivery anchor (head or current
redirect decision), preceding body event, or trailers when completion has them. Each delay uses the shared
millisecond/seconds scalar grammar and canonical spelling. An observed scalar
such as `"10ms"` is ordinary timing; `{"override":"1s"}` is authored timing.
The shared editing form accepts observed plus override and selects one effective
override before checking its nonnegative value. No discarded observation remains
in the runtime model or canonical output.

For example, a completed empty HTTP 503 response can be built without a native
adapter:

```swift
import DioramaCore

enum ExampleFailure: String, Codable, Sendable { case timeout }

let headDelay = try HTTPDelay(milliseconds: .observed(10))
let completionDelay = try HTTPDelay(milliseconds: .observed(0))
let interaction = try HTTPInteraction<ExampleFailure>(
    initialRequest: request,
    result: .received(HTTPResponseNode(
        head: HTTPTimed(
            after: headDelay,
            value: HTTPResponseHead(head: HTTPResponse(status: .serviceUnavailable))),
        body: HTTPBodyDelivery(
            content: .bytes([]),
            conclusion: .returned(HTTPBodyCompletion(after: completionDelay))))))
```

The generic failure value's validation and persisted contract belong to its
adapter. Public lifecycle builders compose validated components; the throwing
`HTTPInteraction` initializer checks derived response lengths against each effective
request method, including recursive redirect and authentication edges; the enums make
contradictory results, multiple conclusions, and failure/open trailers impossible
to construct. Decoding follows the same component construction boundary.

### Tagged lifecycle encoding

The root has only required `initialRequest` and `result` fields. There is no
separate root conclusion. The attempt result shapes are:

```json
{"kind":"received","response":{"head":{"after":"10ms","value":{"status":503,"reasonPhrase":"Service Unavailable","fields":[]}},"next":{"kind":"deliverBody","body":{"content":{"kind":"bytes","text":""},"conclusion":{"kind":"returned","completion":{"after":"0ms"}}}}}}
{"kind":"failed","failure":{"after":"25ms","value":"timeout"}}
{"kind":"open"}
```

The illustrative `"timeout"` is a test adapter failure, not a production HTTP
failure schema. Received responses require `head` and `next`. The continuation
uses an explicit `kind` and exactly its matching payload:

```json
{"kind":"deliverBody","body":{"content":{"kind":"absent"},"conclusion":{"kind":"open"}}}
{"kind":"redirect","redirect":{"after":"0ms","proposedRequest":{"method":"GET","fields":[],"body":{"kind":"absent"}},"outcome":{"kind":"open"}}}
```

Authentication adds `next: { "kind": "authenticate", "authenticate": ... }` with
the response-owned challenge phase as its payload.

`HTTPAfterResponseHead` owns this tagged encoding. Missing/null `next`, unknown
or missing tags, mismatched or competing payloads, and top-level
`body`/`redirect`/`authenticate` fields are rejected. The unreleased earlier response spelling has no retained
reader. Timed heads and failures require `after` and `value`. Bodies require
`content` and `conclusion`.
The body conclusion shapes are:

```json
{"kind":"returned","completion":{"after":"3ms","trailers":{"after":"2ms","fields":[{"name":"X-End","value":"done"}]}}}
{"kind":"failed","failure":{"after":"20ms","value":"connectionLost"}}
{"kind":"open"}
```

Every lifecycle object rejects missing required fields, explicit nulls, unknown
fields, unknown tags, and fields belonging to another tagged case. Missing leaves
never imply open work. Structural errors retain the decoder's coding path;
unknown lifecycle-tag and invalid-delay diagnostics omit the supplied value.
The canonical `lifecycle.json` fixture covers complete bodies, partial failed/open
prefixes, pre-head failure/open, trailers, and all body representations. The
fixture's request and each response's content appear once at their owning node.

This establishes the response/body foundation of DD17's recursive lifecycle.
Redirect, authentication, and optional disposition nodes extend it below;
weighted segmentation and timing allocation are described below. No future
node placeholders, scheduler, capture accumulator, native failure mapping, system
registration, or runtime delivery engine is introduced here. Full system schema
version dispatch remains assigned to H13.

### Response-owned redirect branches

`HTTPResponseNode.next` is exactly one of `.deliverBody(HTTPBodyDelivery)` or
`.redirect(HTTPRedirectPhase)`. The existing `init(head:body:)` builds ordinary
body delivery; `init(head:next:)` selects the strict continuation. The `body`
accessor is optional: it returns ordinary or refused delivery, and nil for a
followed or unanswered redirect. A followed redirect's content is unavailable;
there is no second body slot or synthetic completion to contradict its branch.
Every response persists `head` and one tagged `next` continuation; the runtime
and persisted branch ownership agree.

`HTTPRedirectPhase<Failure>` owns `after`, `proposedRequest`, and `outcome`.
The proposal is a complete prepared `HTTPRequestMessage`, including its exact
method, target, fields, and body. It is not reconstructed from Location or from
a generic redirect status policy. The adapter observes the native proposal,
including resolved relative targets, method/body rewrites, and credential
handling, then applies setup preparation. This component adds no native URL
conversion, interception, forwarding, or redirect policy implementation.

The outcome is exactly one of:

- `.followProposed(result)`: `effectiveRequest` derives from the proposal.
- `.followModified(request, result)`: the edge stores the modified effective
  request once; `effectiveRequest` returns it.
- `.refuse(next)`: the existing response proceeds through
  `HTTPRedirectRefusal.deliverBody` or `HTTPRedirectRefusal.disposition`. An
  observed response-delegate callback gates delivery under the original head.
- `.openAtRecordingHorizon`: no answer was observed. There is no next request,
  body, completion, or decision duration.

Followed results are recursive `HTTPAttemptResult` values, with no repeated
request root. They can receive another response/redirect, fail before the next
head, or remain open while awaiting it. Multi-hop chains therefore preserve
one response per hop and one effective request per nonderivable edge. Redirect
structure is shared in `DioramaHTTP`, parameterized by the adapter's failure
value; H10 requires no additional native-only URLSession supplement fields.
The shared component does not broaden URLSession's advertised capabilities or
infer support for arbitrary status codes; system capability admission remains H13.

A redirect response encodes with required `head` and
`next: { "kind": "redirect", "redirect": ... }`. The redirect payload has required
`after`, `proposedRequest`, and `outcome`. Its outcome shapes are:

```json
{"kind":"followProposed","result":{"kind":"open"}}
{"kind":"followModified","request":{"method":"GET","fields":[],"body":{"kind":"absent"}},"result":{"kind":"failed","failure":{"after":"19ms","value":"timeout"}}}
{"kind":"refuse","next":{"kind":"deliverBody","body":{"content":{"kind":"bytes","text":"redirect"},"conclusion":{"kind":"returned","completion":{"after":"5ms"}}}}}
{"kind":"refuse","next":{"kind":"disposition","disposition":{"after":"3ms","outcome":{"kind":"open"}}}}
{"kind":"open"}
```

The illustrative failure string belongs to a test adapter. All request/body and
result codecs retain their existing strict fields, resource resolution, timing
editing forms, and adapter failure contracts. Missing/null/unknown fields,
competing continuation payloads, unknown continuation/outcome tags, and continuations
under incompatible branches fail decoding. `Fixtures/redirects.json` includes two
hops, a modified request, and refusal with direct body delivery or a disposition.
These remain components of the unreleased version-one system schema; H13 owns
system registration/version dispatch.

`after` starts at the owning head and ends at redirect presentation. The head
delay plus presentation delay must fit the millisecond scalar range. After the
**current** redirect answer returns, its continuation starts a new timing anchor.
For refusal, this anchors direct body delivery or the delay to presenting the
response disposition. The current disposition answer starts another anchor for
its body or failure. Each uninterrupted segment retains checked cumulative
timing and override semantics, and excludes application decision latency.

`continuation(for:requestsMatch:)` is a pure selection operation. Supply a current
prepared `.follow(request)` or `.refuse` decision and the setup's pure equivalence
rule over prepared requests, using the same `HTTPRequestMatcher` projections as
initial selection. It compares the current effective request with the recorded
edge's effective request; storage placement need not match. A compatible follow
returns `.attempt(request:result:)`. Refusal selects `.deliverBody` or
`.disposition` under the existing head. An incompatible
choice/request throws `HTTPRedirectSelectionError.incompatibleDecision`; answering
an open decision throws `.decisionBeyondRecordingHorizon`. These are safe
infrastructure facts, distinct from the generic recorded failure. The caller
reports them through its diagnostic boundary; selection performs no live access.
Until an answer, an open decision remains pending. Scheduling, diagnostic delivery,
and native decision callbacks remain assigned to H12B/I05.

Derived Content-Length uses only ordinary or refused complete body bytes.
Followed and unanswered redirect heads cannot derive length from unavailable
content. A refused body's edited inline/resource bytes resolve the owning head's
marker. Root construction and coding validate response markers against the
request method derived at **each** follow edge, including modified methods.

### Response-owned authentication branches

`HTTPAfterResponseHead.authenticate(HTTPAuthenticationPhase)` is the third
mutually exclusive response continuation. A challenge owns no response copy:
its origin head must have status 401, or status 407 when `isProxy` is true.
Ordinary 401/407 responses without an observed challenge remain ordinary body
delivery. Native capability checks and callback delivery remain adapter work.

The phase contains one `after` delay, one prepared `challenge`, and one `outcome`.
Challenge metadata contains:

- `method`: `basic` or `digest`; security-object methods are unsupported;
- `host`: a nonempty prepared host, and `port`: an integer in `0...65535`;
- optional `protocol` and prepared `realm` strings, preserving absence and empty
  strings distinctly;
- `isProxy` and nonnegative `previousFailureCount`;
- optional `proposedCredential` with safe credential shape.

`HTTPAuthenticationCredential` contains optional prepared `user`, required
`hasPassword`, and `persistence` (`none`, `forSession`, `permanent`, or
`synchronizable`). Password contents, certificate objects, credential stores,
and native descriptions have no field or constructor argument. Construction
and decoding validate structure, not confidentiality: adapters must prepare
identities, including proposed credentials, before admission or comparison.

The recorded outcome is exactly one of:

```json
{"kind":"useCredential","credential":{"user":"fixture-user","hasPassword":true,"persistence":"none"},"retry":{"result":{"kind":"open"}}}
{"kind":"performDefaultHandling","continuation":{"kind":"deliverBody","body":{"content":{"kind":"bytes","text":"denied"},"conclusion":{"kind":"returned","completion":{"after":"5ms"}}}}}
{"kind":"rejectProtectionSpace","continuation":{"kind":"failed","failure":{"after":"9ms","value":"adapter-owned-failure"}}}
{"kind":"cancel","failure":{"after":"11ms","value":"adapter-owned-failure"}}
{"kind":"open"}
```

Use-credential owns a safe credential and a retry. Cancel owns one timed failure,
without a second failure response or terminal conclusion. Default and reject
own one continuation: `retry` with a `retry` object, `deliverBody` with a `body`,
`failed` with a timed `failure`, or `open` with no extra fields. These cases
preserve the native result rather than assuming that refusal always returns a
body or always fails. A body may return or retain its observed failed/open
prefix with the existing body/profile/trailer semantics.

A retry stores required `result` and optional `request`. Omission inherits the
current effective request; a material observed change stores the full prepared
request once on this edge. `effectiveRequest(inheriting:)` resolves that value.
Generated authentication secrets are never shared retry fields. The next result
may introduce another challenged response, a redirect, an ordinary response,
a pre-head failure, or an explicit open horizon. Repeated challenges preserve
their own previous-failure counts and response ownership.

`continuation(for:)` compares the current prepared disposition and, for
use-credential, exact username presence/value, password presence, and persistence.
It returns only the single recorded compatible continuation. It does not verify
password contents, run a Basic/Digest algorithm, invoke a live dependency, or
substitute a recorded answer for the application's current answer. Incompatible
answers throw `HTTPAuthenticationSelectionError.incompatibleDecision`. Answering
an unanswered recorded phase throws `decisionBeyondRecordingHorizon`. The later
delivery owner reports those infrastructure facts separately from dependency
failures. An answered decision followed by `open` is distinct from an unanswered
phase.

Password correctness is outside the replay contract. A different password selects
the same recorded continuation when the prepared username, password presence,
and persistence match, including a recorded successful continuation. Credential
preparation receives only that metadata and cannot inspect password contents.
Consumers are responsible for separately testing correct password entry,
acquisition, and selection; replay exercises handling of recorded authentication
outcomes without establishing that the supplied password would reproduce them
against a server.

Timing follows the redirect decision boundary: `after` runs from owning head to
challenge presentation, and head plus presentation delay must fit the scalar
range. The next attempt, exposed body's first event, or failure starts from
completion of the current answer. Post-decision timing is validated independently;
application decision latency is neither persisted nor added to these delays.
Scheduler delivery remains separate from this pure composition and selection.

A response encodes required `head` and one tagged `next`: body, redirect,
authentication, or disposition. Authentication uses the phase fields above, with no duplicate
response, initial request, or top-level conclusion. Missing required fields,
explicit nulls, unknown tags or fields, invalid challenge/head combinations,
password fields, and branch-incompatible data fail decoding. Unknown method,
persistence, outcome, and continuation tags produce fixed structural descriptions
without rendering their values. Optional metadata is omitted rather than null.
The independent `Fixtures/authentication.json` records a repeated Basic/Digest
chain, proxy rejection, cancellation, and both unanswered and answered-open cases.

Derived Content-Length may use complete body content exposed by default/reject,
including edited resource bytes. It cannot derive from an unexposed challenged
body. Root interaction validation follows inherited and explicit retry methods,
as well as redirect edges, to reject derived response lengths incompatible with
an effective HEAD or CONNECT request. Decoding uses the same validation and
retains the nested coding path.

`DioramaURLSession.URLSessionAuthentication` provides the native metadata boundary.
`capture` accepts only native response-backed Basic/Digest challenges, extracts
safe shape without reading passwords, and prepares proposed credentials.
`decision` maps native answers and prepares selected credentials, with
recording/replay purpose controlling diagnostic health impact. Both use
`HTTPPreparation`'s authentication factories by default: every nonempty username
becomes `redacted`, while absent and empty usernames remain distinct. Password
presence, persistence, and protection-space metadata remain exact. Different
nonempty usernames therefore select the same continuation under the default.

Setup can configure a nonempty constant or a custom username mapping through one
`HTTPAuthenticationUsernameRule`, shared by `authenticationChallenge()` and
`authenticationCredential()`:

```swift
let preparation = HTTPPreparation(authenticationUsername: try .constant("user-a"))
let challengePolicy = preparation.authenticationChallenge()
let credentialPolicy = preparation.authenticationCredential()
```

Supply those policies to `capture` and `decision` respectively. A constant rule
accepts only its exact replacement for prepared nonempty usernames. The default
uses the same rule with `redacted`. An empty constant is rejected so it cannot
collapse nonempty usernames into the empty case. Independent setup configurations
can use `user-a` and `user-b` for separately keyed system instances.

Custom rules supply separate `redact` and `validate` closures for nonempty
usernames. They replace the default rule, receive original captured usernames,
and can preserve distinct synthetic identities within one system instance. They
must produce nonempty safe substitutes, be deterministic and idempotent, and
avoid logging inputs. Absent and empty usernames bypass the rule. Consumer rules
own the confidentiality of values they explicitly permit.

Username rules run before factory-level custom redaction and normalization.
Final validation enforces the selected rule after those transforms and during
validation-only `admitPrepared`; it does not transform loaded or authored values.
Changing the configured constant rejects incompatible fixtures until deliberately
updated. Constructors and Codable remain structural; generic `ValuePreparation()`
still preserves values, and supplying a custom preparation explicitly replaces
the native helper's default. Setup must use compatible policies for proposed,
recorded, and current credentials.

Host, port, protocol, and realm remain exact by default because consumers may use
them to select credentials. The challenge factory supports explicit redaction
and validation of protection-space values. Consumers replacing a realm or host
must account for related request URLs and response fields: `WWW-Authenticate`
and `Proxy-Authenticate` retain their existing exact-by-default behavior. Username
redaction is targeted credential protection, not complete challenge sanitization.

A preparation failure preserves native objects, reports safe facts, and
invalidates recording candidates without publishing raw values. These helpers
do not install delegates or send native answers; Basic/Digest native replay
conformance remains a later adapter gate. The approved Linux Digest exception
remains in effect.

### Optional response disposition

An observed consumer response-delegate callback is encoded as a tagged
`next` with `kind: disposition` and a matching `disposition` payload. This can
be the response's immediate continuation or the `next` inside a redirect
refusal. When an authentication decision results in a new attempt, that
attempt's own response can carry a disposition. The payload contains
`after` (delay to disposition presentation) and one tagged `outcome`:

- `allow` owns `body`, using the existing complete/partial body and conclusion model.
- `cancel` owns one timed `failure`, with no body or competing conclusion.
- `open` has no payload: the consumer has not answered by the recording horizon.

`HTTPResponseDispositionPhase<Failure>` and its outcome are portable stable
components. `DioramaURLSession` adds
`HTTPResponseDispositionDecision.init(urlSessionDisposition:)` for observed
native answers. It converts allow and cancel and rejects unsupported transitions.
Pure selection rejects mismatches and answers beyond an open horizon
as infrastructure facts; the later delivery owner reports them without live
fallback. Caller task cancellation remains separate runtime control.

Ordinary body delivery has no supplement and retains its existing encoding.
Completion/async operations and private forwarding callbacks never manufacture a
consumer decision phase. Absence imposes no delegate-presentation requirement.
A recorded disposition requires proven delegate decision
gating; cancel additionally requires effective cancellation. Full recursive
capability derivation/admission remains H13 and native conformance remains I04.
The accepted Linux exception does not permit encoding cancel followed by success
or erasing an observed decision: capture must diagnose an unrepresentable native
outcome and refuse publication while preserving live behavior.

For a direct disposition, the head and presentation delays share one timing
anchor. Under refusal, presentation is anchored to the current refusal answer.
Body delivery or cancellation failure delays start at completion of the current
disposition answer, excluding application decision latency. Allow can lead to a returned,
failed, or open body; an unanswered decision is distinct from an allowed open
body. Complete exposed bodies retain resource and derived-length semantics.
Strict codecs reject null/missing/unknown/conflicting fields and unsupported
transitions. This extends unreleased version-one components without a version
bump; no native callback wiring or scheduling is introduced.

### Weighted delivery and local timing

`HTTPBodySegment(byteWeight:after:)` stores one nonnegative `Int64` byte weight
and one `HTTPDelay`. At recording time, the weight is the observed segment's
byte count. `HTTPBodyProfile(segments:)` validates a nonempty sequence, including
zero weights, with weight and effective delay sums each bounded by `Int64.max`.
An omitted profile means that no segmented delivery shape is specified. An empty
profile is rejected; use a zero-weight segment to retain an empty delivery event.

`HTTPBodyDelivery(content:profile:conclusion:)` accepts profiles only for inline
bytes or resources. Its immutable internal cases prevent absent/unavailable
content from owning a profile. Returned, failed, and open bodies can all have
profiles, including empty bytes and partial prefixes. Content remains stored once.
The profile's weights need not sum to the current body's byte count.

For example:

```swift
let profile = try HTTPBodyProfile(segments: [
    HTTPBodySegment(byteWeight: 20, after: HTTPDelay(milliseconds: .observed(10))),
    HTTPBodySegment(byteWeight: 80, after: HTTPDelay(milliseconds: .override(25))),
])
let body = try HTTPBodyDelivery<ExampleFailure>(
    content: .bytes([1, 2, 3, 4, 5, 6, 7]),
    profile: profile,
    conclusion: .openAtRecordingHorizon)
let allocations = try profile.allocate(byteCount: 7)
// Byte ranges: 0..<1 and 1..<7; offsets from the head: 10ms and 35ms.
```

`allocate(byteCount:)` accepts the effective nonnegative `Int` byte length, either
from inline bytes or a separately resolved resource. It returns one immutable
`HTTPBodyAllocation` per segment, containing a contiguous `byteRange`, the
successive `after` delay with its authorship, and a cumulative
`offsetMilliseconds` from the response head. No resource I/O occurs here.

For a body length N and positive total weight W, each nonfinal boundary is
`floor(N * cumulativeWeight / W)`. The initial boundary is zero and the final
boundary is N. Products use exact `Int128` arithmetic, which holds every product
of the supported `Int` byte length and `Int64` weight; there is no floating-point
rounding. Adjacent boundaries determine each range. The final segment absorbs
the remainder. This reproduces unchanged observed boundaries exactly and scales
edited bodies deterministically. Examples:

| Weights | Effective byte count | Allocated byte counts |
| --- | --- | --- |
| 20, 80 | 100 | 20, 80 |
| 20, 80 | 7 | 1, 6 |
| 1, 1, 1 | 2 | 0, 1, 1 |
| 1, 1, 1 | 4 | 1, 1, 2 |
| 0, 0, 0 | 7 | 0, 0, 7 |
| 2, 3 | 0 | 0, 0 |

When all weights are zero, all nonfinal boundaries are zero and the final segment
receives the entire effective body. Empty ranges retain their segment and timing
position. Allocation neither copies bytes nor interprets text, so a boundary can
split a UTF-8 scalar. The concatenated ranges always cover the authoritative body
exactly, including at the maximum supported byte count.

All timing is successive and uses effective milliseconds. Profile construction
checks segment sums. Profiled body construction checks segments plus the
conclusion. `HTTPBodyCompletion(after:trailers:)` now throws if the trailers and
completion sum overflows; `HTTPResponseNode(head:body:)` now throws if the head
plus the complete observed body timeline overflows. Thus the invocation-relative
timeline must fit `0...Int64.max` milliseconds, even if every individual delay
fits separately. Open bodies validate only their observed progress, without a
synthetic terminal delay. Negative delays, overflowing sums, and invalid profile
placement fail before runtime use. Decoding follows the same builder boundary
and reports a coding path with a safe structural description.

Bodies optionally encode `segments` alongside required `content` and `conclusion`:

```json
{"content":{"kind":"bytes","text":"edited!"},"segments":[{"byteWeight":20,"after":"10ms"},{"byteWeight":80,"after":{"override":"25ms"}}],"conclusion":{"kind":"open"}}
```

Each segment requires only `byteWeight` and `after`. Unknown/missing/null fields,
negative/fractional/out-of-range weights, empty profiles, and overflowing totals
are rejected. Explicit null `segments` is rejected; omission remains unprofiled.
Canonical writing preserves weights and effective delay overrides, without
derived ranges, totals, offsets, or duplicate segment bytes. Observed-plus-override
timing selects the override before cumulative checks. Editing inline/resource
length does not change the profile or require weights to be rewritten.

`body-allocations.json` contains independent allocation examples, including
rounding and integer bounds. `body-profile.json` proves canonical profile encoding
with empty trailers and authored timing. Incremental recording constructs this
profile from each prepared segment and its observation time.

## Incremental recording

Embed `HTTPRecordingCapture<Failure>` in the adapter's record-mode state.
Configure its body storage policy and, when needed, an interaction policy for
Core's final validation. At invocation, call `HTTPRecordingCapture.begin` under
Core state protection with the capture property's key path, the interaction
track lease, and a stable resource stem based on record identity. Begin reserves
both the record position and the initial request's observation time.

Complete the handle's `initial` reservation with the prepared request event.
For subsequent observations, call `reserve` on the same capture before slow
conversion. Supply the originating attempt number (zero for the root, incremented
for each followed redirect or authentication retry). Prepare the event using
the adapter's selected payload policies outside the lock, then call `complete`
under state protection. Conversion can finish out of order. The accumulator
applies ready events in observation order and checks each against the active
attempt and phase. An adapter that cannot prepare an observation calls
`invalidate` on its operation. Pass the `PreparationFailure` from recording
preparation to preserve the reported stage. Capture diagnostics identify the
record and distinguish invalid reservations, wrong attempts, incompatible
observations, pending preparation, and missing required completions.

Record a decision's answer at the instant the application returns it. The next
head, failure, or body segment uses that instant as its timing anchor. For
default/reject authentication, a subsequent `retry` identifies the observed
branch and any changed request while preserving the answer's anchor. A
`segment` includes its byte weight and delay, including a zero-byte delivery.
Use `content` for whole, unprofiled content, including unavailable content.
Its conclusion uses the preceding timed event as the anchor.

As in [Location capture](evidence/003-G03A-location-incremental-capture.md),
HTTP rounds each monotonic observation timestamp to the nearest millisecond,
with half milliseconds rounding up, before subtracting the previous anchor.
This avoids accumulating rounding error across a sequence of deliveries.
Events that fall on the same rounded timestamp retain a zero delay.

Freeze preserves pending heads, decisions, retries, and partial body prefixes
at their observed horizons. An observed cancel requires its resulting failure,
and observed trailers require successful completion. If capture ends in either
intermediate state, the current schema cannot express the observation and Core
refuses publication. An incompatible event such as successful delivery after a
cancel also invalidates the candidate.

Capture applies body placement to prepared bytes automatically. Each generated
resource stem includes the operation stem, zero-based attempt number, and
content role (request, proposal, modified request, retry, or response).
Length selection uses the effective method at that response and its final body
conclusion. See the [capture evidence](evidence/003-H12A-http-recording-capture.md).

## Recording placement policy

`HTTPBodyStoragePolicy` is immutable recording configuration. Its `request`
method accepts a `PreparedValue<HTTPRequestMessage>`; `response` accepts a
`PreparedValue<HTTPResponseBody>` and `PreparedValue<HTTPResponseHead>`. Call
these methods only for newly recorded content after preparation/redaction, then
admit the resulting value through the system's ordinary validation boundary.
The methods preserve the head and every logical byte. They do not run capture
transforms, access storage, or modify body profiles or lifecycle conclusions.
Native adapter setup will own this configuration when the adapter is introduced.

```swift
let storage = HTTPBodyStoragePolicy(rules: [
    "image/png": .inline,
    "application/json": .automatic(inlineByteLimit: 1_024),
    "application/custom": .resource(fileExtension: "payload"),
], fallback: .standard())
let stored = try storage.request(preparedRequest, resourceStem: "requests/0001")
```

`Rule.inline` always retains inline bytes. `Rule.resource(fileExtension:)`
always creates a resource, including for empty byte content.
`Rule.automatic(inlineByteLimit:fileExtension:)` accepts a `UInt` limit and retains
inline bytes up to and including the limit. Zero keeps empty content inline and
creates resources for nonempty content. `Rule.standard(fileExtension:)` provides
the inclusive 200-byte limit with an optional resource suffix.
Rule factories and policy construction are nonthrowing.
Limits count prepared original bytes, before base64 or JSON escaping; they do
not count characters or the encoded document size. H02's lossless UTF-8/base64
codec continues to select the inline encoding.

Rules have this deterministic precedence:

1. An exact consumer rule key matched against the normalized header hint.
2. A built-in recognized media-type rule, when `useStandardRules` is true (the default).
3. The configurable fallback (default `.standard()`).

Rule keys are stored and used exactly as supplied, without validation,
normalization, or wildcard interpretation. Header hints are lowercased, trimmed,
and truncated before lookup, so keys should use that spelling when intended to
match. Differently cased keys can coexist; an uppercase key does not automatically
match a lowercased hint. Unusual keys can match unusual hints literally. With
standard rules enabled, a fallback change applies only to unknown or unusable hints.
Consumers can override a built-in mapping's threshold with `.automatic`, its
placement with `.inline` or `.resource`, and its suffix with `fileExtension`.

Disable standard placement rules to apply the fallback to every media type
without a consumer override. `HTTPBodyStoragePolicy.allInline` is the nonthrowing
convenience for keeping every newly recorded byte body inline:

```swift
let inline = HTTPBodyStoragePolicy.allInline
let configured = HTTPBodyStoragePolicy(fallback: .inline, useStandardRules: false)
```

Both forms preserve existing baseline resources, absent/unavailable bodies, and
all prepared bytes. Consumers can still add exact overrides when standard rules
are disabled. Media-type lookup and standard extension defaults
remain available whenever a consumer rule or fallback selects resource storage;
`useStandardRules` controls placement only. These methods do not migrate stored
fixtures or change replay behavior.

The standard placement rules and resource extensions are:

| Type | Placement | Default resource suffix |
| --- | --- | --- |
| `image/png`, `image/jpeg`, `image/gif`, `image/webp` | Always resource | `.png`, `.jpeg`, `.gif`, `.webp` |
| `application/json`, `application/` subtypes ending in `+json` | Inclusive 200-byte limit | `.json` |
| `text/html` | Inclusive 200-byte limit | `.html` |
| `text/css`, `text/csv` | Inclusive 200-byte limit | `.css`, `.csv` |
| `text/javascript`, `application/javascript` | Inclusive 200-byte limit | `.js` |
| `text/xml`, `application/xml` | Inclusive 200-byte limit | `.xml` |
| Other `text/` subtypes | Inclusive 200-byte limit | `.txt` |
| Missing, repeated, or unmatched hint | Fallback | `.bin`, unless a rule supplies an extension |

Resource extensions come only from rules: use the selected rule's extension,
then the media-type standard rule's extension if available, then `bin`. The
standard extension remains available when standard placement rules are disabled.
Neither body bytes nor Content-Encoding affect extension selection. A JSON or
image extension does not establish that the bytes are a valid document of that
type; unknown text does not automatically receive `.txt`. Consumers can supply
an explicit extension when they want a different filename. Inline text/base64
encoding remains byte-aware and does not change the bytes.

One Content-Type occurrence supplies a best-effort hint. Take everything before
the first semicolon, trim ASCII spaces/tabs, and lowercase the result. Header
type/subtype and parameter syntax are not validated. The normalized value goes
directly through exact rule lookup and the `text/` prefix or `application/` plus
`+json` suffix defaults. Consequently, malformed hints can still match a family
rule. Missing or repeated Content-Type fields (even identical ones) use fallback;
unmatched hints also use fallback. Configured rule keys are not validated.
Original fields and body bytes remain unchanged; no
charset conversion, decompression, or format sniffing occurs.

Explicit suffixes strip `/` and `\` Unicode scalars at construction and otherwise preserve
the consumer's spelling, case, spaces, Unicode, and dots. There is no suffix
length limit or lowercasing. Nil selects the media-type standard extension or
`bin`; an explicit empty
suffix produces a trailing dot because selection appends the dot literally.
The final resource path still rejects NULs and escaping components, and
filesystem-specific naming and length limits fail during publication. Consumers
are responsible for their chosen suffix. `HTTPBodyStorageError` is removed;
resource-path and filesystem failures still surface when applying or publishing a rule.
`resourceStem` is a caller-assigned relative path,
normally derived from stable recording identity. Selection appends `.` and the
suffix literally; it does not use time, hashes, random identifiers, or counters.
The stem and final path both pass H07's structural resource-path validation. The
caller assigns distinct stems for distinct content. H07 retains responsibility
for aliases, conflicting names/bytes, publication, and owned-byte lifetime.

Absent/unavailable content and existing resource references pass through
unchanged, without even validating the unused stem. The policy never resolves
or rewrites a baseline resource. Decoding, prepared admission, matching, and
replay do not invoke it; changing recording policy cannot migrate stored
representations. Replay needs no writes. Unknown inline content remains exact,
including invalid UTF-8, partial prefixes, BOMs, whitespace, and JSON spelling.
No transcoding, decompression, normalization, or structured JSON is introduced.
H08 owns derived Content-Length and body-edit consistency.

See [H07A evidence](evidence/003-H07A-body-storage-policy.md) and
[the owning plan](plans/003-clean-slate-implementation.md#003-h07a--configurable-type-aware-body-storage-policy).

## Preparation and credential admission

`HTTPPreparation` creates immutable Core `ValuePreparation` policies for request
messages, response heads, and typed body or adapter-owned failure values.
`request` and `response` bind warning diagnostics to the execution reporter and
context; use that same reporter/context when calling `prepare`. HTTP Types field
names supply case-insensitive structural addressing without sorting fields or
changing unrelated bytes. Field rules run before message-level custom redaction,
then normalization, then field-rule validation and custom validation.

The defaults replace Authorization and Proxy-Authorization with fixed Basic,
Bearer, or Digest substitutes. Unknown schemes use `Bearer redacted`. Cookie
values become `redacted`, retaining valid names and order. Set-Cookie also retains
recognized, syntactically supported attributes (Secure, HttpOnly, Partitioned,
SameSite, Path, Domain, Max-Age, and conventional GMT Expires). Unsupported or
malformed cookie syntax uses `redacted=redacted`. Authentication-Info and
Proxy-Authentication-Info become `nextnonce="redacted"`. Malformed recognized
fields emit a safe `http.redaction.replacement-warning` fact without making
the candidate unhealthy. These are deterministic replay fixtures, not credentials
that authenticate with a server. Applications needing specific token formats or
cookie behavior should configure replacements.

`HTTPFieldRedactionPolicy(rules:)`, selected through
`HTTPPreparation(fieldRedaction:)`, overlays supplied rules on the six default
field mappings. Supplied rules take precedence by case-insensitive field name;
each occurrence uses exactly one selected rule. Credential rules are public
`HTTPFieldRedactionRule` values (`.authorization`, `.cookies`, `.setCookie`, and
`.authenticationInfo`) that can also be assigned to custom field names.

Every rule provides independent `redact` and `validate` closures. Capture
redaction returns one `HTTPFieldRedactionResult`:

- `.safe` retains the original field exactly.
- `.replace(value)` replaces its value.
- `.replaceWithWarning(value)` replaces its value and asks the policy to emit
  `http.redaction.replacement-warning`, without recording either value.
- `.remove` omits this occurrence and preserves all remaining field order.

`HTTPFieldValue` carries exact validated bytes and offers optional lossless UTF-8
`text`. Invalid HTTP bytes throw rather than being silently repaired. A retained
or replaced field preserves its original name and HTTP Types indexing strategy.
Rules own the replacement decision; no separate fallback configuration exists.
The policy owns field iteration, warning emission, and removal. Thrown rule
errors use Core's safe preparation-failure path.

`.constant("fixture")` supplies replacement and exact-value validation;
`.constant(HTTPFieldValue)` supports opaque bytes. `.remove` supplies unconditional
removal and validation that rejects any retained occurrence. Custom conditional
rules validate their allowed retained values. An absent field needs no per-field
validation. All retained results, including `.safe`, still undergo final
validation after normalization. Consumers own custom-rule confidentiality and
application-specific validity; a rule can explicitly allow values that the
defaults would redact.

```swift
let preparation = HTTPPreparation(fieldRedaction: HTTPFieldRedactionPolicy(rules: [
    .authorization: try .constant("Bearer fixture-token"),
    .cookie: .remove,
]))
```

Defaults do not discover custom secrets, alter bodies, or redact
WWW-Authenticate/Proxy-Authenticate. Cookie names, supported attributes, URLs,
and ordinary fields can contain sensitive application data and need explicit
consumer rules when applicable. Body/resource preparation remains typed and
opt-in; these helpers perform no resource I/O or native adapter delivery.

Live recording observations and replay inputs use `prepare`. Decoded, edited,
or programmatic baselines use `admitPrepared`: it validates without rerunning
redaction or normalization. The default credential invariant accepts only the
built-in substitute for the recognized shape; constant rules accept only
the configured value, and removal rules reject retained fields. A changed policy therefore rejects incompatible fixtures.
Direct message decoding establishes structural validity only; adapter/system
admission must apply the selected preparation policy before storage or replay.
Full lifecycle and persistence registration integration belongs to later units.

Normalization cannot reintroduce a credential that violates the selected policy.
Failed transforms return Core's safe `PreparationFailure` without retaining the
underlying error or payload. Record-purpose failure invalidates publication;
replay-purpose failure never authorizes live fallback. Input values are immutable;
this layer does not change the caller's original live value. Later adapters own
consumer delivery under DD09's normalized-delivery amendment.

The syntax checks follow [HTTP authentication grammar (RFC 9110)](https://www.rfc-editor.org/rfc/rfc9110.html#name-authentication)
and the [cookie grammar (RFC 6265)](https://www.rfc-editor.org/rfc/rfc6265.html#section-4.1.1).
The supported cookie attribute subset is deliberately conservative; unsupported
extensions trigger whole-field substitution with a warning.

## Prepared request matching

`HTTPRequestMatcher` projects `PreparedValue<HTTPRequestMessage>` into immutable
`HTTPRequestMatchProjection` values. Prepare live inputs with `HTTPPreparation`
and validate stored inputs before projection. Compare projections produced with
the same setup policy. Projection never changes the message or its persisted
representation. Internal adapter routing fields must be removed before admission;
field exclusion is not a privacy boundary.

The standard comparison includes the literal prepared method, scheme, authority,
path/query, logical body, and participating fields. Absent and present-empty
bodies differ. Inline and resource-backed bodies with identical bytes match,
regardless of resource path. Projection defaults to a resource's owned bytes;
callers may supply a controlled projection resolver. Resolver failures surface as
`resourceUnavailable` without exposing the underlying error. Selection performs
no resource I/O.

Default field exclusions are Host, Content-Length, Connection, Keep-Alive,
Proxy-Connection, Transfer-Encoding, and User-Agent. `HTTPMatchFields` is an enum:
`.including(names)` matches only those fields, and `.excluding(names)` matches
every field except those names. Neither case implicitly adds defaults.
`.standard` is `.excluding(defaultExclusions)`. Customize the public
`HTTPMatchFields.defaultExclusions` set with ordinary set operations: subtract
names to opt them back in, or union names to exclude additional fields.
An empty inclusion set ignores every field; an empty exclusion set matches every
field. Name identity is case-insensitive, ordering between different
names is irrelevant, and repeated values retain their order and exact bytes.
Query order, JSON content, and multipart boundaries receive no implicit
normalization.

A typed custom matcher can compare resolved projections. Its comparison must be
a deterministic equivalence relation. `selector(recordedInput:)` adapts projected
records to Core's atomic equivalent FIFO claims; reordered distinct requests
select their own records, and repeated equivalent requests exhaust in recorded
order. Custom Core selectors can report unresolved ambiguity explicitly.
`differences` reports only fixed component categories in deterministic order.
Selector diagnostics include static policy/component labels and Core identities,
never request values, captured field names, body bytes, or resource paths.
Preparation and custom comparison safety remain setup responsibilities.

## Derived Content-Length

A message field may explicitly derive its value from the effective complete body:

```json
{"name":"Content-Length","value":{"derivedFrom":"bodyByteCount"}}
```

Only this field permits the marker. It must be the sole Content-Length field;
`derivedFrom` must be the string `"bodyByteCount"`. Unknown sources, other value
types, extra keys, absent/unavailable bodies, and incomplete responses are
rejected. The earlier boolean marker is not accepted. Literal strings, including
`"auto"` and `"bodyByteCount"`, remain literal. Inline text counts UTF-8 bytes;
base64 counts decoded bytes; resources count explicitly resolved owned bytes.
The runtime HTTP Types head contains the
resolved decimal value, while `derivesContentLength` retains persistence intent.
Re-encoding preserves that intent. Literal strings always remain literal,
including deliberate mismatches and values equal to the current body length.

Incremental recording automatically applies `HTTPContentLength.request` or
`.response` to prepared values after redaction and normalization. Response selection also takes
the effective request method. Selection requires one nonempty decimal field,
a complete body, and equality with its byte count. Leading zeros are accepted;
signs, lists, overflow, repeated values, and mismatches remain literal. Absent
fields remain absent. HEAD and CONNECT methods, informational responses, statuses
204/205/206/304, and any Content-Encoding, Transfer-Encoding, or Content-Range
field conservatively prevent derivation. Failed/open responses retain literals.
The same semantic exclusions reject authored markers during contextual decoding;
interaction construction additionally checks the root request method. Its
initializer throws for derived response lengths paired with HEAD or CONNECT;
decoding uses that initializer so invalid combinations cannot enter a complete
runtime interaction. Literal lengths remain permitted, including mismatches.

Decode response nodes with their bodies: the node resolves the head after loading
content and validating successful completion. A standalone `HTTPResponseHead`
decoder cannot resolve a derived marker and rejects it. Native adapters consume
the resolved node head. Rebuilding a head/message with its ordinary initializer
creates literal fields, providing an explicit way to author mismatches. Request
storage placement preserves an existing marker without changing bytes.

Editing text, base64, or a resource changes the resolved length and weighted
segment allocation without parsing or re-encoding content. Whitespace, duplicate
JSON names, numeric spellings, and escapes remain exact bytes. ETag, Digest,
Content-MD5, signatures, and trailers remain literal and are never recalculated.
Default request matching continues to exclude Content-Length.
