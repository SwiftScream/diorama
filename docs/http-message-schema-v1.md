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

`fields` is an ordered array of objects with required `name` and `value` strings.
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
Derived Content-Length, stream delivery, and native conversion
remain separate plan units. Message builders do not perform those operations or
authorize persisting unprepared secrets.

## Strict lifecycle components

`HTTPInteraction<Failure>` owns one `initialRequest` and one `result`. The
adapter supplies a Sendable stable `Failure` type; the shared HTTP domain defines
no universal transport failure taxonomy. Lifecycle values are immutable and
Sendable, with conditional Equatable and Codable conformances when the failure
type supports them. They contain semantic observations, without executing native
callbacks or deciding whether a test passes.

The attempt result is exactly one case:

- `.received(HTTPResponseNode)` introduces one timed response head and one body
  lifecycle.
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
delay. A response head's delay starts at invocation; failure before a head also
starts at invocation. A body conclusion's delay starts at the head or preceding
body event, or at trailers when completion has them. Each delay uses the shared
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
adapter. Public lifecycle builders compose validated components; the enums make
contradictory results, multiple conclusions, and failure/open trailers impossible
to construct. Decoding follows the same component construction boundary.

### Tagged lifecycle encoding

The root has only required `initialRequest` and `result` fields. There is no
separate root conclusion. The attempt result shapes are:

```json
{"kind":"received","response":{"head":{"after":"10ms","value":{"status":503,"reasonPhrase":"Service Unavailable","fields":[]}},"body":{"content":{"kind":"bytes","text":""},"conclusion":{"kind":"returned","completion":{"after":"0ms"}}}}}
{"kind":"failed","failure":{"after":"25ms","value":"timeout"}}
{"kind":"open"}
```

The illustrative `"timeout"` is a test adapter failure, not a production HTTP
failure schema. Received responses require `head` and `body`. Timed heads and
failures require `after` and `value`. Bodies require `content` and `conclusion`.
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
Redirect, authentication, and disposition nodes remain assigned to H10–H12;
weighted segmentation and timing allocation are described below. No future
node placeholders, scheduler, capture accumulator, native failure mapping, system
registration, or runtime delivery engine is introduced here. Full system schema
version dispatch remains assigned to H13.

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
with empty trailers and authored timing. Resource publication, scheduler delivery,
capture, and native adapters remain separate work units.

## Recording placement policy

[DD17's owner-approved storage amendment](design-decisions/17-http-lifecycle-composition.md#type-aware-body-storage--owner-approved-2026-11-08)
separates this codec from future automatic resource selection. Plan 003 H07 supplies
resource mechanics; H07A adds configurable type-aware placement, thresholds, and
extensions. Images default to resources; text and other content default to
resources above 200 prepared bytes. JSON/HTML resources use `.json`/`.html` where
appropriate. These are planned recording behaviors, not implemented by this codec.
Replay honors stored content. H08 owns derived Content-Length and edited-body
consistency. See the [owning plan](plans/003-clean-slate-implementation.md#003-h07a--configurable-type-aware-body-storage-policy)
for prerequisites, exclusions, and the required future scope checkpoint.

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
