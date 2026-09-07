# Decision 17: HTTP lifecycle composition

- Status: Accepted
- Last updated: 2026-09-06
- Depends on: [Decision 2: Shared and system-specific semantics](02-shared-vs-system-semantics.md),
  [Decision 3: Recorded behaviors](03-recorded-behaviors.md),
  [Decision 4: Replay selection](04-replay-selection.md),
  [Decision 5: Consumption and verification](05-consumption-and-verification.md),
  [Decision 6: Runtime-to-snapshot conversion](06-runtime-to-snapshot-conversion.md),
  [Decision 7: Persistence boundary](07-persistence-boundary.md),
  [Decision 8: Schema compatibility](08-schema-compatibility.md),
  [Decision 9: Normalization and redaction](09-normalization-and-redaction.md),
  [Decision 10: Lifecycle and ownership](10-lifecycle-and-ownership.md),
  [Decision 11: HTTP model strategy](11-http-model-strategy.md),
  [Decision 12: URLSession scope](12-urlsession-scope.md), and
  [Decision 14: Initial real-time replay scheduler](14-real-time-replay-scheduler.md)

## Decision

How does one stable HTTP interaction compose requests, response heads, complete
or partial bodies, delivery timing, redirects, authentication, failures, open
recording horizons, and URLSession-specific behavior without duplicating
messages or fragmenting one URLSession system across platforms?

## Context

An HTTP request is not always one request followed by one aggregate response.
Application-observable behavior may include:

- several response body deliveries;
- redirects with proposed and consumer-modified requests;
- one or more authentication challenges and retries;
- a response head followed by a partial body and transport failure;
- a response head whose body never completes;
- failure before any response head;
- delegate decisions that affect whether delivery continues.

Decisions 11 and 12 established the shared HTTP domain and URLSession boundary,
but deliberately did not select the final composition. A companion adapter
track would require correlation and could drift away from the message it
supplements. A flat event list would permit contradictory terminal states and
make branch ownership difficult to validate. Repeating a complete request and
response at every edge would make authored scenarios noisy and inconsistent.

The stable model therefore uses a recursive semantic tree. Shared HTTP values
appear once at the node where they are introduced. Typed adapter supplements
appear at the exact lifecycle node they refine.

## Interaction boundary

One application HTTP operation is one grouped interaction selected by its
initial prepared request. Once selected, the whole recursive lifecycle is
claimed atomically under decisions 4 and 5.

The root stores one complete initial request and one mutually exclusive result.
Conceptually:

```swift
struct HTTPInteraction<AdapterSupplement> {
    var initialRequest: HTTPRequestMessage
    var result: HTTPAttemptResult<AdapterSupplement>
}

indirect enum HTTPAttemptResult<AdapterSupplement> {
    case received(HTTPResponseNode<AdapterSupplement>)
    case failed(Timed<AdapterSupplement.Failure>)
    case openAtRecordingHorizon
}

struct HTTPResponseNode<AdapterSupplement> {
    var head: Timed<HTTPResponse>
    var next: HTTPAfterResponseHead<AdapterSupplement>
}

indirect enum HTTPAfterResponseHead<AdapterSupplement> {
    case deliverBody(HTTPBodyDelivery<AdapterSupplement>)
    case redirect(HTTPRedirectPhase<AdapterSupplement>)
    case authenticate(HTTPAuthenticationPhase<AdapterSupplement>)
}
```

These declarations explain ownership rather than prescribe final Swift names or
generic implementation. The production model may use type erasure or concrete
URLSession supplement types, but it must retain the same mutually exclusive
shape.

A leaf owns the interaction's state. There is no additional top-level
`conclusion` that could contradict a returned, failed, or open leaf. Finite
recursive structure represents multi-hop redirect and challenge sequences.

## Request messages and ownership

An HTTP request message contains:

- an `HTTPTypes.HTTPRequest` head in memory;
- a body represented as absent, inline bytes, or a resource reference;
- ordered repeated fields preserved by the shared HTTP codec.

Absent and present-but-empty bodies remain distinct when the backend exposes
that distinction. Supported request bodies are complete values. The initial
URLSession system does not record request-body segmentation because it supports
only no body or an in-memory `httpBody`; streamed and upload bodies remain
unsupported.

The initial request is authoritative at the root. Later effective requests are
derived at their lifecycle edge:

- an unchanged followed redirect uses its proposed request;
- a modified followed redirect stores the modified effective request once;
- an authentication retry inherits the current shared HTTP request and adds
  only typed, non-secret challenge decision metadata;
- an adapter may store an explicit effective request on an edge when it observes
  a material change that cannot be derived faithfully.

The continuation does not repeat a derivable request. In particular, generated
authentication secrets are not materialized as shared persisted request fields.

The URLSession adapter captures the prepared request at its interception
boundary. Redaction, pseudonym replacement, and other preparation run before
persistence and matching through the same policy. The original live request is
not mutated merely to produce the stable value.

## Header persistence and derived content length

The in-memory head uses Swift HTTP Types, while Diorama owns its deliberate
persisted field representation. Fields remain ordered and repeated rather than
being flattened into a dictionary.

Most persisted field values are literal. `Content-Length` additionally permits
an explicit body-length-derived value, conceptually:

```json
{
  "name": "content-length",
  "value": { "bodyByteCount": true }
}
```

Recording uses the derived form only when it can prove that the observed field
describes the complete stored body:

- there is exactly one valid `Content-Length` value;
- a complete byte or resource body is present;
- the declared value equals that body's byte count;
- method, status, encoding, and transfer semantics do not make the equality
  ambiguous.

Examples that retain a literal value include a `HEAD` response, a failed or
open partial body, decoded compressed content, and a deliberately mismatched
length. An absent field remains absent. A consumer can replace a derived value
with a literal to author mismatched behavior deliberately.

Replay resolves a derived value against the current resource or inline bytes
before materializing the native head. Editing a body resource therefore updates
a safely derived length without making body size redundant in persistence.
The default matcher continues to exclude `Content-Length` because the logical
request body already participates in matching.

Other byte-dependent fields such as `ETag`, `Digest`, `Content-MD5`, and
signatures remain literal. Diorama cannot generally recreate their algorithms
or keys. A body edit may produce a warning that they could now be stale, but it
does not silently rewrite them.

## Response and body model

Each received response owns exactly one head, one observed body, and one body
conclusion. Response body content has four semantic cases:

- absent;
- bytes, including an explicitly empty value;
- a resource reference with the same byte semantics;
- unavailable because the adapter observed a response but could not expose a
  body for that lifecycle branch.

Inline and resource-backed bytes are interchangeable storage representations.
They do not alter matching, lifecycle, or replay meaning.

A completed response owns its complete delivered body. A failed or open
response owns only the observed prefix; Diorama does not invent bytes that
arrived after the failure or recording horizon. A redirect or authentication
response whose body is not delivered uses unavailable rather than an empty
body. If the consumer refuses the redirect or ultimately exposes an
authentication response, that response owns its delivered body exactly once.

HTTP statuses, including `4xx` and `5xx`, are completed HTTP responses when
their message delivery succeeds. They are not transport failures.

## Weighted body segmentation

The full logical body is authoritative and persisted once. A delivery profile
stores successive delays and nonnegative byte weights without repeating body
content:

```json
{
  "body": { "resource": "bodies/response.json" },
  "segments": [
    { "byteWeight": 20, "after": "10ms" },
    { "byteWeight": 80, "after": "25ms" }
  ]
}
```

At recording time, each weight equals the observed segment's byte count. When
the body is unchanged, proportional allocation therefore reproduces the exact
recorded boundaries. If an authored edit changes the body length, replay
deterministically scales the boundaries while retaining the segment count and
delays.

Allocation uses cumulative proportions and deterministic integer rounding. The
final segment absorbs any remainder so the profile always covers the effective
body exactly. Splitting bytes does not need to respect UTF-8 scalar boundaries;
native network delivery may also split encoded text at arbitrary byte offsets.

Zero weights are permitted when they reflect an observed empty delivery or an
authored timing shape. If every weight is zero and a later edit makes the body
nonempty, the final segment receives all bytes. Empty effective content never
requires a positive weight.

Absent and unavailable body cases have no segment profile. A byte or resource
body may have a profile even when empty. The strict runtime model uses the
effective allocation, so persisted body edits cannot create out-of-range
segments or contradictory byte coverage.

## Human-readable JSON resources

Exact application-observed body bytes remain the default. When a body has an
`application/json` or `+json` media type and contains valid UTF-8 JSON, the
initial file repository should store it as an exact `.json` resource. This
makes common bodies visible to editors, diffs, and security review without
parsing and re-encoding them.

The repository does not pretty-print or otherwise mutate the resource. Number
spelling, whitespace, key order, duplicate names, escapes, and signatures stay
byte-for-byte as observed until a consumer edits the file. Such an edit
deliberately changes the replayed bytes. Weighted segmentation and derived
`Content-Length` values adapt mechanically.

Readable storage is not a confidentiality boundary. Decision 9's redaction and
normalization pipeline still runs before any body enters the main document or a
resource.

An explicit semantic JSON policy may be added later. It could persist a
structured JSON value, match requests semantically, and replay a deterministic
canonical encoding. It must be opt-in because re-encoding changes byte
semantics, dependent headers, and segmentation fidelity. The initial
implementation does not retain an exact body and a competing structured body
as two authoritative representations.

## Body conclusion and trailers

Body delivery has one mutually exclusive conclusion:

- returned successfully after a nonnegative successive delay;
- failed with one timed adapter failure after the observed prefix;
- open at the recording horizon after all recorded segments.

Optional HTTP trailers belong only to the successfully completed branch. When
an adapter exposes them, they occur after the final body segment and before the
completion event, with their own successive delivery delay. The shared HTTP
model can represent trailers even though the first URLSession capability
profile need not expose them.

A response with absent or empty body content can still complete after a delay.
Failure before a response head belongs to `HTTPAttemptResult.failed`; failure
after a response head belongs to the body or decision continuation that owns
the observed progress.

## Redirect lifecycle

A redirect phase is attached to the response head that caused it. It owns:

- the proposed next request exactly once;
- the delay before the redirect is presented;
- the prepared runtime decision;
- the compatible recorded continuation.

Its mutually exclusive outcomes are:

- follow the proposed request and continue with the next attempt result;
- follow a modified effective request and continue with the next attempt
  result;
- refuse and deliver the redirect response body as the returned response;
- remain open because no decision was observed by the recording horizon.

Replay presents the native redirect and lets current application policy decide.
The prepared decision selects the recorded branch. A different or incompatible
decision is a serious Diorama infrastructure diagnostic; it does not use the
network. Diorama does not persist how long application code took to decide.
Post-decision delivery timing is anchored to completion of the current decision.

The redirect response is stored once. A followed branch marks its body
unavailable; a refused branch delivers its stored body. Recursive continuations
represent multi-hop redirects without a parallel correlation track.

## HTTP authentication lifecycle

Initial authentication support is limited to task-level HTTP Basic and Digest
challenges associated with a `401` or `407` response. The challenge attaches to
that response head, which is stored once.

The stable URLSession challenge supplement includes the supported prepared
semantics of:

- host, port, protocol, realm, and proxy status;
- previous failure count;
- the existence and safe metadata of a proposed credential;
- the URLSession challenge disposition;
- for use-credential behavior, prepared username identity and persistence
  policy, but never the password.

The challenge outcome is one of:

- use a prepared credential and continue with a retry;
- perform default handling and follow its recorded continuation;
- reject the protection space and follow its recorded continuation;
- cancel the challenge and deliver the resulting recorded task failure once;
- remain open at the recording horizon.

A continuation may retry, expose the challenged response body, fail, or remain
open according to what the native dependency did. Repeated challenges recurse
through the same response-owned structure. A retry inherits the current shared
request unless the adapter can demonstrate a distinct effective request that
must be stored explicitly.

Replay presents a fresh native challenge and uses the current prepared
disposition and credential shape to select the recorded continuation. A branch
mismatch is an infrastructure diagnostic with no live fallback. Application
decision latency is not persisted; timing after the decision starts when the
decision returns.

Challenge cancellation is a recorded lifecycle decision and is distinct from
the caller canceling a `URLSessionTask`. Server trust, client certificates,
identities, and challenges without a representable HTTP response remain
unsupported.

## URLSession response disposition

The URLSession adapter may attach a typed response-disposition phase immediately
after a response head, but only when the native delegate decision actually
occurs. Completion-handler and async operations do not synthesize a phase merely
because their effective behavior is to allow the response.

Supported recorded outcomes are:

- `.allow`, followed by body delivery;
- `.cancel`, followed by the resulting stable failure once;
- open when the delegate did not answer by the recording horizon.

`.becomeDownload` and `.becomeStream` remain unsupported. Replay of a recording
containing this supplement requires the compatible delegate capability, and
the current decision must select its recorded branch. Decision latency is not
persisted; body timing starts from the allow decision.

A recording without the supplement remains usable across supported completion,
async, and delegate presentation styles. Its absence does not create a hidden
requirement to reproduce a callback that was never observed.

## URLSession failure representation

Failures are URLSession adapter semantics rather than a premature universal
HTTP failure taxonomy. The stable failure contains:

- the `NSError` domain and code;
- an optional recognized `URLError` name while preserving unknown numeric
  codes;
- an optional prepared failing URL;
- a bounded allowlist of typed property-list-compatible `userInfo` values that
  are useful and safe for replay.

It does not persist localized descriptions, arbitrary underlying-error graphs,
trust or certificate objects, or unreviewed platform values. An unsupported
observable `userInfo` entry produces a warning containing only its key and
value type. The entry is omitted and recording otherwise continues healthily.

Record and passthrough deliver the original native `Error` to application code.
Replay constructs a fresh `NSError` or `URLError` carrying the stable supported
semantics. It does not claim native object identity or arbitrary error-subclass
reconstruction.

A canceled error caused by observed caller task cancellation is runtime
control and is not persisted. An independently observed dependency cancellation
failure may be recorded. Diorama misses, ambiguity, capability failures, and
expired executions use a separate infrastructure error domain.

## Timing semantics

HTTP retains only behaviorally meaningful local delays. Every persisted delay
is nonnegative and successive:

- invocation to the first response head or pre-response failure;
- response head to redirect, authentication, disposition, or first body event;
- the current decision to its continuation;
- one body segment to the next;
- final segment or head to trailers, completion, or failure.

Local timing avoids coupling independent interactions to incidental global
recording chronology. It also makes insertion and manual editing local. The
scheduler accumulates the delays into invocation-relative deadlines and applies
decision prerequisites as defined by decision 14.

Runtime application decision latency is deliberately excluded. If the current
decision returns late, the next recorded delay begins then. Callback queue,
executor, thread, task identity, and Foundation's internal scheduling are not
stable timing values.

## Timing overrides and re-recording

Every persisted HTTP delay is deliberately overrideable under decision 3,
including head, challenge, redirect, disposition, body segment, continuation,
completion, and failure delays.

The tolerant reader accepts observed and override forms together and selects
the override. Canonical writing emits only the override. A fresh observed value
may remain available in a transient recording report but does not create a
second authoritative persisted value.

Re-recording builds a fresh interaction track, then associates old and new
groups using the configured prepared request matcher. Repeated equivalent
groups pair by prior stable sequence. Within a paired group, timing overrides
are retained only along the same compatible structural path and decision
branch. An override whose node or branch no longer exists is dropped and may be
reported informationally.

Request heads, response heads, bodies, failures, and branch choices are directly
editable fixture data but are not sticky authored overrides in the initial
implementation. Re-recording replaces them with fresh observations. Future
message- or subtree-level overrides can be added deliberately without changing
the initial timing rule.

## Presentation independence

The lifecycle records URL loading behavior rather than which supported
URLSession convenience delivered it. Replay sends the response head, allocated
body segments, trailers where supported, and conclusion through the
instrumented loading pipeline. Foundation then exposes that behavior through:

- async `data` conveniences;
- completion-handler data tasks;
- delegate-based data tasks.

Completion and async consumers receive an aggregate body after the same overall
lifecycle timing. Delegate consumers can observe the recorded segment delivery
shape. Diorama does not promise callback queue identity or exact executor
interleaving.

Adapter-specific decision supplements constrain replay only when present. An
application cancellation during replay stops future delivery and leaves the
claimed recording used but potentially incomplete; it is not itself a snapshot
mismatch.

## Open interactions and finalization

An open interaction replays all recorded phases and then schedules no terminal
outcome. Before a response, the operation remains pending without a callback.
After a partial body, the delivered prefix remains visible and the operation
does not finish. An unanswered redirect or challenge remains at that decision
barrier.

The pending replay remains owned by the execution until caller cancellation or
scenario finalization. Finalization:

- refuses new work;
- cancels remaining scheduler registrations and adapter machinery;
- unregisters URLSession routing state;
- prevents later Diorama-owned callbacks;
- reports open or not-yet-concluded claimed interactions.

An escaped instrumented session becomes inert after finalization. A later
request produces a deterministic infrastructure failure and never contacts the
live dependency. Finalization does not invent a persisted cancellation or
successful completion for an open recording.

## Adapter composition and capabilities

URLSession-specific phases and failures are typed supplements embedded in the
HTTP lifecycle node they refine. They do not use a separately correlated
companion track. Shared messages are therefore stored once, ordering is
structural, and an adapter phase cannot drift away from its response.

There is one URLSession system identity and persistence schema across Apple
Foundation and FoundationNetworking. Each bridge declares the lifecycle
capabilities it has proved through conformance tests. Required capabilities are
derived from the recording's structure rather than duplicated as a persisted
platform name or manually maintained list.

Setup validates the complete recording against the local adapter before
playback. An unsupported node produces a serious setup diagnostic. It is never
ignored or approximated. A Darwin recording can replay through
FoundationNetworking when every node belongs to their common tested capability
profile.

Implementation begins with bodyless GET on macOS and Linux. Redirect,
authentication, failure, delegate, trailer, and other capabilities become
advertised per bridge only after their conformance slices pass. This may produce
temporarily different capability profiles without creating different systems
or scenario formats.

## Validation boundary

The persisted `Codable` representation is an editing format. Decoding is
followed by validation that constructs the strict recursive runtime enums.
Public scenario builders pass through the same validation boundary rather than
exposing unchecked state constructors.

Validation includes:

- finite, nonnegative delays and byte weights;
- body profiles only on byte or resource content;
- derived content lengths only where an effective complete body can supply a
  length;
- redirect and authentication continuations only under their corresponding
  branches;
- one mutually exclusive leaf at every result and conclusion;
- valid resource references and availability under decisions 7 and 8;
- recognized tagged cases for the declared HTTP system schema version.

Flexible forms explicitly accepted by earlier decisions remain valid input.
These include observed-plus-override timing and body resources whose length no
longer equals the original sum of segment weights. Validation normalizes them
into one effective runtime interpretation; canonical writing emits the selected
form.

An invalid document produces path-specific diagnostics identifying the
attachment, interaction, attempt, and field. Replay does not partially claim or
consume the interaction and never falls through to a live request. Unknown tags
are schema incompatibilities rather than optional events.

## Explicitly excluded lifecycle surfaces

The initial HTTP lifecycle does not model:

- informational `1xx` responses until an implemented adapter exposes a concrete
  application-observable requirement;
- invisible transport retries;
- DNS, connection establishment, TLS negotiation, proxy internals, or cache
  internals;
- task metrics, upload progress, task identifiers, KVO, or callback queues;
- streamed uploads, upload tasks, download tasks, WebSockets, stream tasks,
  protocol upgrades, server push, or background sessions.

Cookies are prepared HTTP fields rather than a separate cookie-store snapshot.
Multipart, form, protobuf, and other media types remain opaque exact bytes
unless a future explicit typed normalization policy is configured.

Only behavior observable at a supported application networking boundary enters
the lifecycle. An adapter does not manufacture wire or transport events that
its native surface did not expose.

## Implementation progression

The implementation plan should divide this decision into reviewable slices:

1. shared request, response, field, body, and resource values with custom
   persistence;
2. strict recursive response, body, failure, and open runtime models;
3. weighted segment allocation and successive timing validation;
4. exact JSON resource selection and conditional content-length derivation;
5. bodyless GET record and replay through URLSession on macOS and Linux;
6. aggregate and segmented body delivery across async, completion, and delegate
   forms;
7. stable URLSession failure conversion and warning diagnostics;
8. redirects and request derivation;
9. Basic and Digest authentication continuations;
10. response-disposition supplements;
11. open interaction, cancellation, finalization, and escaped-session behavior;
12. platform capability derivation and cross-bridge conformance fixtures;
13. timing override and re-record correspondence tests.

Each incomplete slice advertises only its proven capability set and rejects
unsupported playback without live fallback.

## Consequences

Benefits:

- The type structure cannot represent a successful response and an open or
  failed conclusion simultaneously.
- Shared HTTP messages are not duplicated across URLSession lifecycle phases.
- Redirect and authentication chains remain editable and structurally local.
- Exact bodies remain readable while body edits do not invalidate segment
  metadata or safely derived lengths.
- The same recording can serve supported URLSession presentation styles and
  platform bridges.
- Adapter-specific semantics remain explicit without fragmenting the shared
  HTTP domain.

Costs:

- Recursive custom persistence and validation are more involved than a flat
  exchange array.
- Redirect, authentication, and delegate replay require native conformance
  evidence on every advertised platform.
- Body edits can make literal validators or signatures stale and can only
  approximate the original segment boundaries after length changes.
- Exact byte defaults do not automatically provide semantic JSON matching or
  pretty printing.

## Explicit non-decisions

This decision does not determine:

- final public Swift type and case names;
- the exact JSON key spelling of every tagged lifecycle node;
- semantic JSON canonicalization or JSON-path body redaction;
- message- or subtree-level authored overrides;
- a universal cross-adapter failure taxonomy;
- cross-client replay before a second HTTP adapter proves a common profile;
- the deferred URLSession task families and transport surfaces listed above;
- implementation-specific URLProtocol correlation and delegate-proxy details.

## Review questions

1. **Lifecycle ownership: Resolved.** One interaction owns an initial request
   and a recursive attempt result; response nodes and mutually exclusive leaves
   store each shared value once.
2. **Response body: Resolved.** A response owns one head, observed content, a
   weighted delivery profile where applicable, and one returned, failed, or
   open conclusion.
3. **Redirects: Resolved.** The response owns the proposed request and decision;
   followed requests derive the next attempt, while refusal delivers the same
   response body.
4. **Authentication: Resolved.** Basic and Digest challenges are typed response
   phases with redacted credential identity and recursive continuations.
5. **Grammar: Resolved.** Tagged recursive enums make terminal and branch states
   mutually exclusive rather than relying on optional-field combinations.
6. **Failures: Resolved.** URLSession owns a stable NSError-based failure with
   bounded safe metadata; unsupported user-info values warn and are omitted.
7. **Response disposition: Resolved.** The supplement exists only when the
   native delegate decision occurs and supports allow, cancel, and open.
8. **Timing overrides: Resolved.** Every HTTP delay is overrideable and survives
   re-recording only at a corresponding compatible path.
9. **Request ownership: Resolved.** The root stores the initial prepared request;
   redirect and authentication edges derive later requests without duplication.
10. **Presentation: Resolved.** Supported async, completion, and delegate APIs
    consume one lifecycle rather than defining separate recordings.
11. **Platforms: Resolved.** One URLSession schema uses structurally derived
    capability requirements across Foundation and FoundationNetworking.
12. **Open behavior: Resolved.** Replay remains pending after recorded progress
    until caller cancellation or quiescent finalization.
13. **Body authoring: Resolved.** Exact JSON resources are the initial readable
    representation; byte weights scale segmentation after edits, and safely
    equivalent content lengths are derived.
14. **Scope and validation: Resolved.** Trailers have a defined completion
    position, low-level transport surfaces are excluded, and persisted editing
    forms must validate into the strict runtime tree before replay.

## Accepted answer

One HTTP interaction is a recursively composed, atomically claimed lifecycle.
The root owns its initial prepared request. Each response head owns exactly one
body, redirect, or authentication continuation, and every path ends in one
returned, failed, or open state. URLSession phases and failures are typed
supplements embedded at their semantic node rather than a companion track.

Bodies are stored once as exact inline or resource bytes. Valid JSON uses exact
`.json` resources for review. Timed byte weights reproduce original segmentation
until editing and scale deterministically afterward. A content length proven to
equal a complete stored body is explicitly derived; ambiguous values remain
literal.

Local successive delays replay one-to-one through the scenario scheduler and
support authored overrides. The same lifecycle normally serves async,
completion, and delegate URLSession APIs. Structural capability validation
permits one schema across Apple Foundation and FoundationNetworking without
silently degrading unsupported behavior or contacting a live dependency.
