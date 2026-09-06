# Decision 12: URLSession scope

- Status: Accepted
- Last updated: 2026-09-06
- Refined by: [Decision 17: HTTP lifecycle composition](17-http-lifecycle-composition.md)
- Depends on: [Decision 3: Recorded behaviors](03-recorded-behaviors.md),
  [Decision 5: Consumption and verification](05-consumption-and-verification.md),
  [Decision 6: Runtime-to-snapshot conversion](06-runtime-to-snapshot-conversion.md),
  [Decision 9: Normalization and redaction](09-normalization-and-redaction.md),
  [Decision 10: Lifecycle and ownership](10-lifecycle-and-ownership.md),
  [Decision 11: HTTP model strategy](11-http-model-strategy.md)

## Decision

Which `URLSession` features belong to the initial production-quality adapter,
and which must be rejected explicitly rather than recorded or replayed only
partially?

## Context

`URLSession` is a family of APIs rather than one request/response call. It
contains data, upload, download, WebSocket, and stream tasks; completion-handler,
delegate, and async conveniences; redirects; authentication challenges;
caching; cookies; task metrics; progress; background transfers; and several
forms of request body.

The POC inserts a `URLProtocol` into a copied session configuration and returns
a new session. It forwards every operation through a separate data task,
buffers the final response, and records only successful `HTTPURLResponse`
values. That implementation does not unregister its process-wide routing state,
records neither errors nor intermediate phases, loses redirect chains, ignores
body streams, and routes with an ordinary header that can collide with consumer
input.

The clean implementation should not claim all of `URLSession`. A smaller
surface is production-quality when:

- every supported operation has tested record, replay, passthrough, timing,
  cancellation, failure, and cleanup behavior;
- unsupported configurations and operations produce Diorama infrastructure
  diagnostics before they can use a live dependency during replay;
- adapter-created sessions and global routing state obey decision 10;
- native values cross into the shared HTTP model only through decision 6's
  stable conversion boundary;
- limitations are public contract rather than incidental gaps.

## Interception mechanism

The initial adapter should continue to use a per-session custom `URLProtocol`.
Apple exposes `URLSessionConfiguration.protocolClasses` for this purpose, and
`URLProtocolClient` can deliver responses, data, redirects, failures, and
authentication challenges back into the URL Loading System.

This mechanism has hard boundaries:

- a session copies its configuration when created, so instrumentation must
  happen before the returned session exists;
- `URLSession.shared` cannot be retrofitted with a per-session protocol;
- custom protocols are unavailable to background sessions;
- one configured protocol class is not itself a configured instance, so
  multiple instrumented sessions require execution routing;
- forwarding must prevent the Diorama protocol from intercepting itself.

The adapter should not use global `URLProtocol.registerClass`. It should insert
its protocol only into the configuration of the session it creates. That keeps
unrelated sessions outside Diorama's interception boundary.

## Session construction and ownership

The preferred setup API should accept a `URLSessionConfiguration`, optional
delegate, and optional delegate queue, then create and return a new instrumented
`URLSession` owned by the adapter lease. This is more honest than taking an
already-created session and suggesting it can be modified in place.

Setup should:

1. copy the consumer configuration;
2. reject a background configuration;
3. validate unsupported delegate capabilities that can be detected up front;
4. reserve an internal routing field and reject a configuration that already
   supplies it;
5. insert the Diorama protocol ahead of consumer protocol classes;
6. create any private forwarding session from the uninstrumented configuration;
7. create the returned session and register its routing lease;
8. return it only after the complete scenario execution is running.

Consumer protocol classes remain in the forwarding configuration in their
original order. This allows record-mode tests to use a custom protocol as their
live dependency. A forwarded request carries a private `URLProtocol` property
that prevents Diorama re-entry; that property is never an HTTP field or part of
the stable request.

The session-routing mechanism may use a reserved, randomly valued HTTP field
because a static `URLProtocol` class otherwise has no configured instance from
which to obtain the execution. If so, it must:

- reject rather than overwrite a consumer value with the reserved name;
- verify the unguessable value against the active lease;
- remove the field before conversion, matching, diagnostics, or forwarding;
- never persist or log the value;
- fail a missing, unknown, or expired route without live fallback;
- unregister the route during finalization.

A narrower mechanism discovered by the implementation spike is preferable, but
the POC's silent overwrite and permanent strong registry are not acceptable.

The adapter owns the returned session and its private forwarding machinery. At
the recording horizon it refuses new work, removes execution routing, and uses
session invalidation consistent with decision 10. It does not invalidate a
separately consumer-owned session. A minimal forwarding tail for an already
running live task may finish without retaining or mutating the scenario.

## Supported initial session configurations

The initial adapter should support copied default and ephemeral configurations
on validated platforms, subject to documented changes required for deterministic
interception:

- background identifiers are rejected;
- URL caching is disabled for the instrumented and forwarding path so replay
  consumption cannot be bypassed by an unrecorded cache hit;
- consumer cookie and credential storage settings are preserved where the
  supported request and authentication flows can reproduce them;
- timeout, connectivity, proxy, TLS, connection, and additional-header settings
  are used for live forwarding but are not themselves persisted as HTTP
  interaction behavior;
- existing custom protocol classes are preserved behind Diorama for record and
  passthrough forwarding.

Disabling cache is an observable configuration change and must be documented at
setup. A future cache capability could record cache hits and delegate policy,
but the first HTTP interaction system should not pretend that cache state is a
network response recording.

## Supported task family

The initial adapter should support HTTP and HTTPS `URLSessionDataTask`
operations created through:

- `dataTask(with: URL)`;
- `dataTask(with: URLRequest)`;
- their completion-handler variants;
- delegate-based data tasks;
- Swift async `data(from:)` and `data(for:)` conveniences, including their
  task-delegate forms where the conformance spike proves equivalent behavior;
- HTTP Types Foundation conveniences that ultimately use the supported data-task
  surface.

The request may have no body or an in-memory `httpBody`. The body is converted
to the stable HTTP body before matching or recording. Empty and absent bodies
retain the distinction selected in decision 11.

Only `http` and `https` schemes are part of the HTTP attachment. An operation
using another scheme on the instrumented session must fail with an unsupported-
operation diagnostic in every mode rather than bypass the adapter unexpectedly.

## Explicitly unsupported task families

The initial adapter should reject:

- `URLSessionUploadTask`, including data, file, streamed, and resumable forms;
- `URLSessionDownloadTask`, including resume-data forms;
- `URLSessionWebSocketTask`;
- `URLSessionStreamTask`;
- a data task whose request uses `httpBodyStream`;
- conversion of a data task to a download or stream task;
- non-HTTP URL schemes.

These are separate behavior shapes, not minor overloads. Upload streams require
replayable production and backpressure of request bytes. Download tasks own
temporary files, progress, resume data, and file lifetime. WebSocket and stream
tasks are bidirectional streams rather than HTTP interactions. Adding any of
them should be a later capability decision with its own stable behavior and
tests.

The body resource mechanism from decision 7 can still keep a large recorded
data-task response out of the encoded JSON. It does not by itself reproduce the
native contract of a download task.

## Iterative implementation

The accepted initial surface is a milestone boundary, not one implementation
change. Work should proceed through small reviewable slices, beginning with a
simple HTTP GET with no body and expanding through request bodies, failures,
delegate delivery, redirects, and authentication.

Every intermediate slice must expose an accurate temporary capability boundary.
An operation not yet implemented follows the same explicit unsupported-operation
path as a permanently excluded task; it cannot fall through to live networking
during replay. The adapter is not considered production-quality for the
accepted initial milestone until the complete supported matrix and conformance
suite pass.

## Response delivery

A supported data-task recording should retain:

- each received `HTTPURLResponse` converted to one shared response head;
- each response body segment and its logical observation time when the URL
  Loading System exposes incremental delivery;
- the complete logical response body without duplicating bytes;
- each response-owned returned, failed, or open conclusion;
- redirect and supported authentication phases described below.

The full logical body is authoritative and is persisted once, either inline or
through a resource reference. Valid UTF-8 JSON bodies use exact `.json`
resources in the initial file repository without being parsed or pretty
printed. Delivery segmentation is separate metadata. A conceptual persisted
profile resembles:

```text
body: <complete logical content or resource reference>
segments:
  - { byteWeight: 128, after: 120ms }
  - { byteWeight: 512, after: 25ms }
  - { byteWeight: 83,  after: 65ms }
```

Segment entries do not repeat their bytes. On recording, weights equal observed
byte counts. Replay allocates contiguous slices using their cumulative
proportions, so an unchanged body retains exact boundaries and an edited body
scales deterministically without invalidating the profile. Successive delays
determine delivery. For a failed or open response, the stored body is only the
prefix observed by the failure or recording horizon; Diorama does not invent
unobserved content.

This keeps textual or otherwise human-readable body content together for review
and editing while retaining application-observable callback shape. A resource-
backed body uses the same metadata alongside its reference. When an observed
`Content-Length` is provably equal to a complete stored body, persistence uses
decision 17's explicit body-length-derived field value; ambiguous lengths remain
literal.

Replay reports each response and body segment through `URLProtocolClient` using
its effective successive delays. Foundation then supplies the API form chosen
by the consumer: delegate callbacks, completion-handler aggregation, or an
async return. Diorama does not separately record those three convenience shapes
when they express the same underlying data-task behavior.

For a data delegate, an actually observed response-disposition callback becomes
a typed lifecycle supplement. `.allow`, `.cancel`, and an unanswered open
decision are supported. `.becomeDownload` and `.becomeStream` are unsupported
operation transitions and must produce a diagnostic rather than partially
changing task type. Completion and async APIs do not synthesize an implicit
allow phase.

Application task cancellation remains runtime control rather than persisted
behavior. It stops remaining replay delivery and releases the claim resources;
the selected recording remains used and may be reported incomplete under
decision 5. Task suspension, resumption, priority, progress objects, KVO, task
identifiers, and byte counters are not stable snapshot values. The initial
adapter should preserve ordinary native control where feasible but does not
promise deterministic replay of those incidental observations.

## Redirects

Redirect chains are required initial behavior rather than a later enhancement.
For each redirect, the adapter records:

- the redirect response;
- the proposed next request;
- its relative delay within the interaction lifecycle;
- whether the client followed, modified, or refused the redirect;
- a modified effective request only when it cannot be derived from the proposed
  request.

Replay reports the redirect through the URL Loading System so automatic policy,
a session delegate, or a task-specific delegate can make its current decision.
That decision selects the compatible recorded continuation under decisions 3
and 4. Application code does not receive a Diorama identifier. A redirect
refusal can conclude with the redirect response; an unanswered decision can
remain open at the recording horizon.

The adapter must preserve the group across the new `URLProtocol` request created
by a followed redirect without putting correlation data into the stable HTTP
fields. Cross-origin credential handling follows Foundation's native request
construction plus Diorama's preparation rules.

Redirect support requires conformance tests for automatic following, delegate
refusal, delegate modification, multiple hops, relative locations, method/body
rewrites, loops or limits, cancellation, and replay timing.

## Authentication challenges

Task-level HTTP authentication challenges are required initial behavior for
the authentication methods that can be represented without platform security
objects. The adapter should record a stable, redacted challenge containing the
supported `URLProtectionSpace` semantics, proposed-credential metadata,
previous-failure count, response-owned challenge presentation delay, and
decision. The associated failure response is the same shared response head and
is not repeated inside the supplement.

Replay presents a native challenge and observes the current disposition:

- use a credential;
- perform default handling;
- reject the protection space;
- cancel the authentication challenge.

Raw credentials never enter the recording. The replay disposition and prepared
credential shape select a compatible continuation. Diorama does not verify
caller cancellation, and an unanswered challenge can produce an
`openAtRecordingHorizon` interaction.

The initial supported methods should be HTTP Basic and HTTP Digest. Additional
password-based methods can be added only with stable redaction and round-trip
tests. Server trust, client certificates, and other challenges containing
`SecTrust`, identities, certificates, persistence stores, or platform security
policy are explicitly unsupported. They cannot be reconstructed faithfully
from a portable snapshot and must not be serialized by description.

Default TLS validation needed for ordinary HTTPS forwarding remains live
transport behavior. The exclusion concerns application-observable custom
challenge handling and replay, not use of HTTPS itself.

## Failures

Supported URL loading failures should be recorded and replayed as a typed
URLSession adapter failure. The stable value retains NSError domain and code,
an optional recognized `URLError` name without rejecting unknown numeric codes,
an optional prepared failing URL, and a bounded allowlist of safe typed
property-list-compatible `userInfo` values. It does not persist arbitrary error
graphs, platform security objects, or localized descriptions.

Unsupported observable `userInfo` entries produce a warning containing only
their key and value type, are omitted, and do not by themselves make recording
unhealthy. Record and passthrough still deliver the original native `Error`;
replay constructs a fresh `NSError` or `URLError` carrying the supported stable
semantics. HTTP 4xx and 5xx statuses remain successful HTTP responses, not URL
loading failures. Application cancellation is runtime control and is not
recorded as a dependency failure unless Foundation independently reports a
supported failure before caller cancellation is observed.

A replay miss, ambiguity, expired execution, or unsupported operation produces
a distinct Diorama infrastructure error and no live fallback. Native values
outside the stable failure's documented representation are never converted by
description.

## Delegate surface not initially reproduced

The initial adapter does not record or synthesize:

- `URLSessionTaskMetrics` callbacks or transaction metrics;
- cache proposal callbacks or `CachedURLResponse.userInfo`;
- connectivity-waiting and delayed-request delegate decisions;
- upload progress or replacement body-stream callbacks;
- download progress, temporary-file callbacks, or resume data;
- WebSocket open/close callbacks;
- session-level server-trust or client-certificate decisions;
- task conversion to download or stream tasks.

Where a delegate advertises an unsupported decision-bearing callback and the
adapter can detect it during setup, setup should fail with a capability
diagnostic. Where only an operation reveals the unsupported surface, that
operation fails through the URL Loading System with a Diorama infrastructure
error. The adapter must not merely omit a callback and return an apparently
successful replay.

Incidental observation-only callbacks need not all make setup fail. For example,
metrics are explicitly unavailable during replay and consumers must not attach
the URLSession system when their test requires metrics. The conformance spike
must determine which optional delegate methods can be detected reliably and
which exclusions can only be documented until the relevant operation occurs.

## Passthrough semantics

Passthrough uses the same returned instrumented session and lifecycle lease but
does not convert, record, match, or replay stable HTTP behavior. It forwards
supported operations through the uninstrumented configuration.

Unsupported task families should remain unsupported in passthrough for the
initial adapter. Allowing them only in passthrough would let a per-attachment
mode change alter whether application code is valid and could create accidental
live traffic in a mixed setup. A consumer needing unrestricted URLSession
passthrough should use its original uninstrumented session instead.

## Explicit failure boundary

Failure should occur at the earliest reliable point:

- invalid configuration or detectable delegate capability: scenario startup;
- unsupported task or request body: task loading before forwarding or matching;
- unsupported response transition, challenge, phase, or required native value:
  when observed, preserving live behavior in record mode while making the
  candidate unhealthy; omission-approved error metadata instead follows
  decision 17's warning rule;
- replay of a recording requiring an unsupported feature: scenario startup when
  discoverable, otherwise before delivering the incompatible phase.

Every failure enters the execution ledger and diagnostic sink. A task with an
error channel receives a Diorama infrastructure error. The returned session
must not fall through to Foundation's built-in HTTP handler after Diorama has
rejected an operation.

## Platform support

Linux is an intended URLSession platform from the beginning, not a substitute
for a future AsyncHTTPClient adapter. FoundationNetworking provides
`URLSession`, per-session `protocolClasses`, `URLProtocol`, and the
`URLProtocolClient` event surface needed by the proposed boundary. Its
URLSession implementation is nevertheless a distinct libcurl-based,
best-effort compatibility implementation rather than Apple's URL Loading
System. Source compatibility therefore does not establish matching redirect,
challenge, delegate, cancellation, error, segmentation, or cleanup behavior.

These platforms should use one public Diorama URLSession system and one stable
persistence model. Platform differences belong behind that system boundary:

- an Apple-platform URLSession bridge integrates with Foundation's native URL
  Loading System;
- a non-Darwin bridge integrates with FoundationNetworking;
- both convert through the shared DioramaHTTP model from decision 11;
- platform-specific native details may be retained only as stable adapter
  supplements where they are useful and representable.

The bridges may occupy conditionally compiled files or separate package targets.
That implementation boundary must not create separate scenario system types or
platform-specific copies of the HTTP matching, redaction, and persistence
rules. A recording made on macOS must be replayable on Linux, and vice versa,
when it uses only capabilities proven on both platforms.

Support is capability- and platform-specific rather than an assertion of total
Foundation parity. The adapter derives the capabilities required by a loaded
recording from its phases and stable values. Setup rejects replay when the local
bridge has not passed the corresponding conformance tests. This does not require
persisting the consumer's setup configuration.

The initial implementation targets macOS, iOS, and Linux. The first bodyless
GET slice must run on both macOS and Linux so a fundamental interception
difference is discovered before the architecture grows around Darwin-only
behavior. Subsequent redirect, authentication, failure, delegate, and lifecycle
features are advertised on each platform only after their conformance cases
pass there. The common tested capability profile defines the portable
cross-platform promise; one platform may temporarily expose a larger tested
profile than another.

FoundationNetworking requires a conditional import on Linux and lacks several
Apple configuration facilities, including background sessions,
`waitsForConnectivity`, Multipath TCP, and platform Security/`SecTrust`
integration. These are already outside the initial supported surface. Exact
error metadata, redirect and authentication behavior, callback segmentation,
and toolchain/libcurl stability remain evidence questions rather than assumed
parity.

tvOS and visionOS can be added when the relevant interception tests run there.
watchOS remains excluded because Apple documents custom `URLProtocol`
limitations on watchOS. Other non-Darwin platforms remain unadvertised until
their FoundationNetworking bridge passes an equivalent suite.

## Required interception spike

Before production code is divided into implementation tasks, a narrow spike
must test the proposed `URLProtocol` boundary on current macOS and Linux
runtimes, followed by an iOS simulator run for the Apple mobile target. It
should use a local deterministic protocol or server and answer only these
questions on every platform that will advertise the corresponding capability:

1. Are all supported data-task creation forms intercepted before cache or live
   network access?
2. Can task families and `httpBody` versus `httpBodyStream` be distinguished
   early enough to reject unsupported operations?
3. Can response heads and multiple data segments be recorded and reproduced for
   delegate, completion-handler, and async consumers?
4. Can redirect chains be correlated while preserving automatic, modified, and
   refused decisions?
5. Can HTTP Basic and Digest challenges bridge dispositions without persisting
   credentials?
6. Do cancellation, finalization, routing expiry, and custom protocol forwarding
   avoid callbacks, leaks, and live fallback after the execution horizon?

The exit artifact is an executable test matrix and a short findings note, not
production architecture. If redirects or authentication cannot be reproduced
faithfully through `URLProtocol`, decision 12 must be reopened to narrow the
surface or adopt a more explicit integration. The implementation must not
quietly collapse those phases as the POC does.

## Worked examples

### Async JSON request

Application code calls `session.data(for:)` with an HTTP POST, in-memory JSON
body, `Content-Type`, and `Accept`. Record mode captures the prepared shared
request, response head, body segments, timing, and conclusion. Replay matches
the prepared fields and body and returns through the same async API without
contacting the forwarding session.

### Delegate-controlled redirect

A data-task delegate receives a 302 redirect and substitutes a different request.
The recording retains the response, proposed request, actual request, decision,
and timing in one group. Replay invokes the delegate again and selects the
recorded continuation matching its current decision.

### Unanswered HTTP challenge

A server sends an HTTP Basic challenge and the task delegate retains its
completion handler without responding before test teardown. Finalization
records the challenge phase and `openAtRecordingHorizon`. Replay presents the
challenge and remains pending after recorded phases until caller control or
scenario cleanup ends it.

### Unsupported file upload

Application code creates an upload task from a file on an instrumented replay
session. Diorama diagnoses an unsupported URLSession task and completes it with
an infrastructure error. It does not open a live connection and does not treat
the file as an absent request body.

### Transport timeout

A supported data task fails with `URLError.timedOut`. Record mode preserves the
native failure for the application and stores its stable code and timing.
Replay reconstructs a `URLError` after the same effective relative delay. An
HTTP 504 remains a normal recorded response.

## Recommendation

Build the initial URLSession adapter around a new, adapter-owned, non-background
session configured with a per-session `URLProtocol`. Support HTTP(S) data tasks
with absent or in-memory bodies across delegate, completion-handler, and async
forms. Record incremental response delivery, redirects, HTTP Basic and Digest
challenges, supported NSError-based URLSession failures, timing, and open
horizons.

Explicitly reject other task families, body streams, non-HTTP schemes, cache
semantics, metrics-dependent tests, task conversion, platform-security
challenges, background sessions, existing/shared-session mutation, unsupported
platform capabilities, and unvalidated platforms. Route every unsupported
replay operation to a Diorama infrastructure error with no live fallback.

Expose one URLSession system and persistence model backed by platform-specific
Apple Foundation and FoundationNetworking bridges. Include macOS and Linux in
the first bodyless-GET implementation slice, then grow the advertised profile
on each platform only where executable conformance tests prove record/replay
symmetry and lifecycle cleanup. Cross-platform portability covers the tested
intersection of those profiles.

## Consequences

Benefits:

- Common application data requests have a useful, lifecycle-complete adapter.
- Redirects, HTTP authentication, transport failures, timing, and incomplete
  work are not collapsed into a final successful response.
- Unsupported URLSession behavior fails visibly instead of reaching the
  network during replay.
- Configuration-first construction and adapter leases fix the POC's permanent
  routing registry.
- A tested surface gives later upload, download, and WebSocket work honest
  boundaries.
- One stable system model permits scenarios using the common capability profile
  to move between Apple platforms and Linux.

Costs:

- The first adapter is substantially more involved than a completion-handler
  data-task wrapper.
- Consumers must inject a newly created session rather than use
  `URLSession.shared` or an already-created instance.
- File transfer, WebSocket, caching, metrics, and security-challenge tests need
  future capabilities or another test strategy.
- URLProtocol behavior needs platform-specific integration tests and may force
  the redirect or authentication scope to be revisited.
- Platform capability profiles may differ temporarily and add CI cost across
  Swift toolchain and libcurl combinations.
- Disabling URL cache changes the supplied configuration intentionally.

## Explicit non-decisions

This proposal does not determine:

- final URLSession attachment and dependency-access API names;
- the internal delegate proxy, authentication sender, or redirect-correlation
  implementation;
- the exact reserved routing field name;
- the complete safe URLSession `NSError` metadata allowlist;
- upload, download, WebSocket, stream, or cache capability designs;
- server-trust fixture or certificate virtualization;
- support for tvOS, visionOS, watchOS, Windows, or Android;
- the exact supported Linux distributions, Swift toolchains, and libcurl
  versions, which the implementation plan must turn into a concrete CI matrix;
- performance limits for inline response segments versus resource spooling;
- deterministic replay of URLSession task metrics, progress, or KVO.

## Review questions

1. **Session boundary: Resolved.** Setup accepts configuration and delegate
   inputs and returns a newly created adapter-owned session. Background
   configurations are rejected, and the initial adapter neither instruments
   `URLSession.shared` or an existing session nor retains an existing session as
   its live forwarding engine. A template-copying convenience is unnecessary
   for the initial implementation.
2. **Task boundary: Resolved.** The initial surface supports HTTP(S) data tasks
   with no body or an in-memory body across delegate, completion-handler, and
   async forms. It explicitly rejects upload, download, WebSocket, stream,
   body-stream, resume, conversion, and non-HTTP operations. Implementation is
   iterative, beginning with simple bodyless GET requests; every intermediate
   slice rejects behavior it has not yet implemented.
3. **Response and redirect fidelity: Resolved, refined by decision 17.** The
   initial milestone records response heads, weighted timed body segmentation,
   completion, lifecycle progress, and full redirect decisions rather than only
   one aggregate result. Persistence stores the exact logical body once. Byte
   weights reproduce original boundaries until an edit and scale afterward;
   redirect edges derive effective requests without duplicating them.
4. **Authentication and failures: Resolved, refined by decision 17.** The
   initial milestone supports redacted HTTP Basic and Digest challenge
   lifecycles and typed NSError-based URLSession outcomes. Unsupported
   `userInfo` values warn and are omitted while the original live error still
   reaches application code. Platform-security challenges remain unsupported,
   and normal HTTPS default validation remains supported.
5. **Configuration and delegate exclusions: Resolved.** URL caching is disabled,
   while supported cookie and credential storage is preserved. Metrics, delayed
   requests, connectivity callbacks, task conversion, platform-security
   handling, and other unsupported delegate behavior fail at the earliest
   detectable boundary rather than being silently omitted. The same capability
   restrictions apply in passthrough mode.
6. **Evidence and platforms: Resolved.** Diorama has one URLSession system and
   stable model, with platform-specific Apple Foundation and
   FoundationNetworking bridges. Linux is an intended target from the first
   bodyless-GET slice. Each bridge advertises only capabilities proven by its
   conformance suite, and recordings are portable across platforms when they
   use the common tested profile. Other platforms remain unadvertised until
   equivalent tests pass.

All original URLSession scope review points are resolved. Decision 17 later
selects their concrete recursive lifecycle composition, and the updated
consistency review covers the complete set of accepted decisions before plan
synthesis.

## References

- [URLSession](https://developer.apple.com/documentation/foundation/urlsession)
- [URLSessionConfiguration protocol classes](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/protocolclasses)
- [URLProtocol](https://developer.apple.com/documentation/foundation/urlprotocol)
- [URLProtocolClient](https://developer.apple.com/documentation/foundation/urlprotocolclient)
- [URLSessionDataDelegate](https://developer.apple.com/documentation/foundation/urlsessiondatadelegate)
- [URLSessionTaskDelegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate)
- [Swift Corelibs Foundation](https://github.com/swiftlang/swift-corelibs-foundation)
- [FoundationNetworking URLSession](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/FoundationNetworking/URLSession/URLSession.swift)
- [FoundationNetworking URLSessionConfiguration](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/FoundationNetworking/URLSession/URLSessionConfiguration.swift)
- [FoundationNetworking URLProtocol](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/FoundationNetworking/URLProtocol.swift)
- [Handling an authentication challenge](https://developer.apple.com/documentation/foundation/handling-an-authentication-challenge)
