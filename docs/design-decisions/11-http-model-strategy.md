# Decision 11: HTTP model strategy

- Status: Accepted
- Last updated: 2026-09-06
- Refined by: [Decision 17: HTTP lifecycle composition](17-http-lifecycle-composition.md)
- Depends on: [Decision 2: Shared and system-specific semantics](02-shared-vs-system-semantics.md),
  [Decision 3: Recorded behaviors](03-recorded-behaviors.md),
  [Decision 4: Replay selection](04-replay-selection.md),
  [Decision 6: Runtime-to-snapshot conversion](06-runtime-to-snapshot-conversion.md),
  [Decision 8: Schema compatibility](08-schema-compatibility.md),
  [Decision 9: Normalization and redaction](09-normalization-and-redaction.md)

## Decision

Should first-party HTTP integrations share transport-neutral stable semantics
from the start, or should each backend retain a native model until two working
integrations demonstrate what is genuinely common?

## Context

Diorama is intended to support more than one networking library. `URLSession`
is the first backend, AsyncHTTPClient is an important server-side candidate, and
future Swift networking APIs should be able to participate without redefining
HTTP method, target, field, status, and body semantics.

The POC persists wrappers around `URLRequest` and `HTTPURLResponse`. This works
for one backend but makes Foundation part of the stable model and loses
information such as repeated header fields. It also records only the original
request and final response, not the lifecycle phases accepted in decision 3.
The clean-slate design does not need to preserve that representation.

At the other extreme, not every observable client behavior is an HTTP message:

- Foundation authentication challenges can represent server trust, client
  certificates, or URL-loading policy in addition to HTTP authentication;
- native error types and cancellation mechanics differ between clients;
- redirect-following policy belongs partly to the client;
- streaming, backpressure, metrics, caching, and delegate callbacks expose
  different surfaces;
- a backend may normalize, synthesize, decompress, or hide wire-level details
  before application code observes them.

A shared model should therefore capture real protocol-level reuse without
claiming that every HTTP client has an identical runtime contract.

## Current ecosystem input

Apple's `swift-http-types` package provides version-independent `HTTPRequest`,
`HTTPResponse`, and `HTTPFields` currency types. Its core types are `Sendable`,
`Hashable`, and `Codable`; `HTTPFields` preserves order and repeated fields. The
separate `HTTPTypesFoundation` product provides conversions to and from
Foundation URL-loading types.

Those are useful protocol message heads, not a complete Diorama model. The
package does not own Diorama's body-resource representation, lifecycle timing,
group conclusions, authored overrides, replay matching, redaction, schema
version, or backend-specific behavior. Directly adopting its synthesized
`Codable` output as Diorama's file contract would also delegate snapshot schema
stability to another package.

AsyncHTTPClient has its own request, response, body, error, streaming, and
event-loop APIs. An eventual adapter would still need an explicit native
boundary even when its semantic messages use `HTTPTypes` values.

## Options considered

### Persist backend-native wrappers

Each adapter can define stable wrappers around its native request, response,
and error types.

This minimizes the first URLSession implementation and preserves native
concepts directly. It duplicates method, target, header, status, body,
normalization, redaction, matching, and diagnostic behavior in every backend.
It also makes scenario authoring and tooling backend-specific even where the
meaning is ordinary HTTP.

### Invent complete Diorama HTTP primitives

Diorama can define its own method, target, header, and status types in addition
to its body and lifecycle types.

This gives complete API and persistence control. It duplicates established
validation and collection semantics, increases conversion work, and creates
another HTTP currency model for consumers to learn.

### Compose shared HTTP currency types into Diorama-owned records

A first-party HTTP domain can use `swift-http-types` for protocol message heads
while Diorama owns the stable body, interaction, policy, diagnostics, and file
schema around them. Concrete adapters compose this shared domain with the
native lifecycle and failures they can faithfully reproduce.

This establishes useful reuse immediately without forcing backend-only behavior
into a false universal abstraction. It adds one focused package dependency and
requires explicit persistence code at the Diorama boundary.

## Proposed semantic layers

### Diorama HTTP domain

An optional `DioramaHTTP` product should own reusable protocol semantics:

- request and response message heads based on `HTTPRequest` and `HTTPResponse`;
- a stable body representation supporting inline bytes and typed resource
  references;
- optional message trailers where an adapter exposes them;
- protocol-level response and redirect values;
- HTTP canonicalization, redaction, matching, validation, and safe diffs;
- deterministic Diorama-owned `Codable` representations and HTTP system schema
  versions;
- shared test builders for programmatic scenarios.

`DioramaCore` remains unaware of HTTP and does not depend on `swift-http-types`.

### Concrete HTTP adapter

Each adapter should own:

- conversion between its native values and the shared HTTP values;
- the precise API surface it intercepts or wraps;
- application-observed streaming and callback behavior;
- native redirect, challenge, cache, task, cancellation, and error semantics;
- native materialization during replay;
- explicit rejection of shared or recorded features it cannot reproduce.

For example, `DioramaURLSession` can depend on `DioramaHTTP` and
`HTTPTypesFoundation`. A future AsyncHTTPClient product can depend on
`DioramaHTTP` and its native NIO types without introducing NIO into the shared
HTTP product.

### Adapter-specific stable semantics

An integration can compose shared HTTP messages with typed adapter-specific
phases and failures. Those values remain stable, versioned, and persistable;
they are not arbitrary native objects or string descriptions.

Decision 17 selects typed supplements embedded in the lifecycle node they
refine. The composition preserves these rules:

- common HTTP values are not duplicated as subtly different backend structs;
- backend-specific values have their own stable type and schema identity;
- unsupported backend behavior fails explicitly under decision 6;
- an adapter cannot silently drop a recorded phase to claim compatibility.

URLSession-specific redirect, authentication, disposition, and failure values
therefore live in the recursively composed HTTP interaction rather than a
separately correlated companion track. Shared HTTP messages remain stored once,
and another adapter can define its own typed supplements without changing the
shared message types.

## Stable HTTP message values

Conceptually, Diorama needs values resembling:

```swift
struct StableHTTPRequest {
    var head: HTTPRequest
    var body: StableHTTPBody?
}

struct StableHTTPResponse {
    var head: HTTPResponse
}

enum StableHTTPBody {
    case inline(bytes: [UInt8])
    case resource(HTTPBodyResource)
}
```

These declarations are illustrative, not final APIs. Decision 17 places the
response body, optional trailers, timing, and conclusion in a response-owned
lifecycle node rather than allowing a response value and a second terminal
state to contradict each other. A body reference is a semantic reference
governed by decision 7, not a machine-specific loading object. Empty, absent,
and unavailable bodies remain distinguishable where HTTP or the native API
gives them different meaning.

The persisted format should encode an explicit Diorama shape for method,
scheme, authority, path, ordered fields, status, body, and trailers. It may use
`HTTPTypes` values in memory and custom encoding logic without promising that
the package's own encoded representation is Diorama's format. Diorama's HTTP
system version governs this schema under decision 8.

Fields must remain an ordered list and allow repeated names. Converting them to
a dictionary would corrupt meaningful values such as multiple `Set-Cookie`
fields and make round trips dependent on backend combination rules.

## Observed semantics, not packet capture

Diorama records the semantic behavior presented at the supported client API
boundary. It is not a packet capture or HTTP conformance proxy.

The shared value therefore represents the request or response as the adapter
can faithfully present it to application code. TLS records, connection reuse,
HPACK/QPACK state, transfer framing, proxy negotiation, and raw compressed bytes
are not included merely because they existed on the wire. If an adapter exposes
some of that information as supported application behavior, it belongs in a
typed adapter-specific value.

This distinction must be documented per adapter. For example, if a native
client delivers a decoded response body, Diorama records that application-
observed body and the adapter must materialize a consistent replay rather than
claiming to preserve raw wire bytes.

## Bodies and delivery profiles

Exact logical body bytes are recorded by default, as accepted in decision 9.
Inline versus resource-backed storage is a persistence choice and must not
affect matching or replay meaning.

Some client surfaces return one aggregate body, while others expose response
heads, chunks, trailers, and backpressure. The shared HTTP design must not
assume that every body is delivered in one callback. It can separate:

- the logical message content used for semantic equality and authoring; and
- an optional timed delivery profile used when a supported adapter exposes
  streaming behavior.

Decision 17 makes this concrete as timed byte weights. On first recording the
weights equal observed segment lengths, reproducing exact boundaries while the
body is unchanged. If a consumer edits the body, proportional allocation keeps
the profile valid and approximates the original delivery shape. Each delay is
successive, and segment entries never duplicate body bytes.

The first URLSession adapter can replay that profile through the URL loading
pipeline, after which Foundation selects delegate, completion-handler, or async
presentation. Another adapter that supports only aggregate delivery must reject
a recording whose application-observable delivery requirements it cannot
reproduce.

## Lifecycle and redirects

One HTTP operation remains a grouped interaction under decision 3. Decision 17
represents its initial request, protocol-level phases, and mutually exclusive
conclusion as a recursive semantic tree with local successive timing. An HTTP
status, including a 4xx or 5xx status, is a successful HTTP response rather
than a transport failure.

Redirects illustrate the common/native split:

- the redirect response and proposed or followed request have HTTP meaning and
  can use shared HTTP values;
- whether a redirect is followed, how credentials are changed, and what native
  callback is made belong to the adapter and its configured client behavior.

Authentication challenges require the same care. HTTP `401`/`407` responses
and challenge fields are protocol values. A URLSession server-trust or client-
certificate challenge is a URL-loading event and must not be mislabeled as a
portable HTTP phase. Decision 12 determines which URLSession challenge surface
the initial adapter can record and replay.

## Failure model

HTTP message values can be shared more broadly than client failure values.
DNS, connection, TLS, timeout, protocol, body-consumption, and policy failures
may have common categories, but application code often observes a concrete
native error with backend-specific codes and properties.

The initial shared HTTP layer should not invent a universal error enum before
two adapters demonstrate a faithful mapping. Each adapter should define a
stable, typed failure representation around its supported native behavior. A
later common failure taxonomy can be additive and can coexist with typed native
detail where exact same-adapter replay needs it.

This means sharing HTTP values does not initially promise that a complete
scenario recorded through one backend can be replayed through another. It does
ensure that request, response, body, matching, transformation, and diagnostic
logic are reusable rather than locked inside Foundation wrappers.

## Cross-adapter portability

Portable scenario replay should be an explicit capability, not an implication
of both adapters importing `DioramaHTTP`.

A recording is portable only when:

- its request, response, body, and protocol phases are in the shared profile;
- its failure or conclusion can be represented by the target adapter;
- it contains no required adapter-specific lifecycle behavior;
- the target adapter declares and validates support for every used feature.

The initial implementation does not need cross-adapter replay because only one
production backend is planned. When a second backend is implemented, shared
conformance fixtures should demonstrate the portable subset. Unsupported
portability produces a setup diagnostic and never silently degrades the
recording or contacts a live dependency.

## Matching policy

The first-party standard HTTP matcher should operate on prepared shared values.
Its recommended default projection includes:

- method;
- scheme and authority;
- path and query in their prepared representation;
- exact logical request-body bytes, including absent versus present-empty where
  the model preserves that distinction;
- all prepared request fields except a small documented default exclusion set.

The initial excluded fields are:

- Diorama's internal instrumentation fields, which must not enter the prepared
  request at all;
- `Host`, because the prepared authority already represents it;
- `Content-Length`, because the logical body already represents it;
- connection and framing fields `Connection`, `Keep-Alive`,
  `Proxy-Connection`, and `Transfer-Encoding`;
- `User-Agent`, because it is commonly incidental, while setup can opt it back
  in when a server varies behavior by client identity.

This default includes representation and behavior selectors such as `Accept`,
`Content-Type`, `Accept-Language`, `Content-Encoding`, `Range`, conditional
request fields, prepared authorization and cookies, and custom fields. HTTP is
extensible, so a fixed allowlist would silently ignore meaningful fields such
as a consumer's API-version or feature header.

Consumers can add exclusions, opt an excluded field back in, select a strict
inclusion set, or provide a typed matcher. Header comparison uses
case-insensitive names, ignores ordering between different field names, and
preserves the order of repeated values for the same name where their order is
meaningful.

Normalization is separate. Query order, generated multipart boundaries, JSON
object order, and other domain-specific equivalences are not silently changed
by the matcher; consumers configure typed preparation rules where literal bytes
or volatile field values are too strict. Credential redaction also precedes
matching, so the matcher and its diagnostics see only prepared substitutes,
never a live authorization or cookie secret. Constant substitutes can collapse
several identities into equivalent candidates until scenario-scoped pseudonyms
are implemented.

## Default credential treatment

The first-party HTTP preparation policy should recognize these credential
surfaces by default:

- request `Authorization` and `Proxy-Authorization` fields;
- request `Cookie` fields;
- response `Set-Cookie` fields;
- `Authentication-Info` and `Proxy-Authentication-Info` fields.

Transformation should preserve syntax needed for replay where practical: an
authorization scheme, cookie names, and cookie attributes can remain while
secret values receive safe substitutes. If a recognized field cannot be parsed
for structural replacement, the default rule replaces its complete value with
a deterministic safe substitute and emits a diagnostic. It makes the recording
unhealthy only if it cannot construct a valid safe value. It never falls back
to recording the raw credential. Custom API-key fields require consumer
configuration because their names and semantics are not standardized.

`WWW-Authenticate` and `Proxy-Authenticate` describe challenges rather than
presenting client credentials, so they remain unchanged by the default privacy
rule. A consumer can normalize their volatile nonce or realm parameters when
needed.

HTTP bodies remain unchanged by default even when their media type is JSON,
form data, or multipart data. Typed body sanitizers are opt-in.

## Dependency and availability posture

`swift-http-types` should be a dependency of the optional HTTP product, not the
core. The implementation plan must select a release compatible with Diorama's
chosen Swift tools version and platforms rather than importing an arbitrary
latest revision.

Public Diorama HTTP APIs may use `HTTPTypes` currency values. Persisted schema,
authored overrides, and migrations remain owned by Diorama. A future incompatible
change in the dependency must be absorbed at the adapter/domain boundary and
must not silently change snapshot JSON.

## Worked examples

### URLSession request and response

The URLSession adapter converts a native request into a shared HTTP request head
and stable body. It records a response using the shared status, ordered fields,
and body while its stable URLSession failure and callback phases remain adapter-
owned. Replay converts shared values back through the Foundation boundary.

The snapshot does not archive `URLRequest` or `HTTPURLResponse`, reconstruct a
fictional HTTP version, or flatten response fields into a dictionary.

### Future AsyncHTTPClient adapter

An AsyncHTTPClient facade converts native NIO method, URL, fields, and buffers
to the same shared HTTP message values. It retains event-loop, streaming,
backpressure, and error behavior in its adapter layer. The common matcher and
redaction policies need not be rewritten.

### Redirect requiring native behavior

A recording contains a shared redirect response and target request plus a
URLSession-specific delegate decision. Replaying it through URLSession can use
both parts. A future adapter that cannot reproduce the delegate decision rejects
cross-adapter replay rather than returning only the final response.

### Repeated response fields

A response contains two `Set-Cookie` fields. The stable ordered field list
preserves both independently. Default credential preparation replaces their
values while retaining names and relevant attributes; persistence never
collapses them into one dictionary entry.

## Recommendation

Create a first-party transport-neutral HTTP domain from the start. Use
`swift-http-types` for in-memory request, response, and field currency values,
and wrap them in Diorama-owned body and lifecycle records with a stable custom
`Codable` schema.

Share protocol message values, matching, normalization, redaction, diagnostics,
and builders. Keep native conversion, client failure fidelity, callbacks,
streaming mechanics, and non-HTTP lifecycle events in concrete adapters. Do not
promise cross-adapter scenario replay until a second adapter proves and tests a
portable feature profile.

## Consequences

Benefits:

- The first stable HTTP model is not tied to Foundation.
- Future adapters reuse meaningful domain behavior and human-authored fixtures.
- Ordered repeated fields and modern version-independent message semantics are
  preserved.
- Diorama retains control over its schema and compatibility promise.
- Backend differences remain visible instead of being erased by the shared
  layer.

Costs:

- The initial URLSession implementation carries an additional focused package
  dependency and conversion boundary.
- Diorama still needs owned body, lifecycle, persistence, and policy types.
- Complete scenarios are not automatically portable across adapters.
- Adapter-specific lifecycle composition requires recursive custom persistence
  and validation as specified by decision 17.
- Dependency releases must be selected deliberately for toolchain compatibility.

## Explicit non-decisions

This proposal does not determine:

- exact Swift product and public type names;
- the final stable body or external-resource API;
- a universal cross-client failure taxonomy;
- a guarantee of cross-adapter scenario replay;
- streaming segmentation and backpressure support beyond decision 12;
- exact URLSession conversion and supported APIs;
- support for WebSocket, HTTP upgrade, CONNECT tunnels, server APIs, or raw wire
  capture;
- the concrete compatible `swift-http-types` release requirement.

Decision 17 resolves the adapter-specific phase composition, weighted delivery
profile, exact JSON resource, and conditional content-length semantics that were
previously deferred here.

## Review questions

1. **Shared scope: Resolved.** Diorama introduces a shared HTTP domain
   immediately for protocol messages and policies, while native lifecycle and
   failure semantics remain in each adapter. The first implementation does not
   persist Foundation wrappers or wait for a second backend to establish this
   domain boundary.
2. **Currency types and schema: Resolved.** The shared domain uses
   `swift-http-types` for in-memory request, response, and field values. Diorama
   owns its body and lifecycle models and explicitly encodes its versioned
   persisted schema rather than adopting the dependency's encoded form as the
   file contract.
3. **Portability promise: Resolved.** Shared HTTP values enable reuse without
   initially promising that a complete scenario can move between URLSession and
   another backend. A second adapter must define and prove a portable feature
   profile. Required adapter-specific behavior is rejected explicitly rather
   than silently discarded.
4. **Matching defaults: Resolved.** The standard matcher uses the prepared
   method, target, logical body, and request fields by default. It excludes
   Diorama-internal, authority/body-derived, connection/framing, and
   `User-Agent` fields through a small documented default set. Consumers can
   configure inclusion or exclusion. Redaction and normalization occur before
   matching, so credentials are compared only as prepared substitutes.
5. **Credential defaults: Resolved.** The default HTTP policy replaces
   authorization, proxy authorization, cookie, set-cookie, authentication-info,
   and proxy-authentication-info credential material. It preserves useful field
   structure where possible and otherwise uses a deterministic safe whole-field
   substitute with a diagnostic, never the raw value. Challenge fields and HTTP
   bodies remain unchanged unless configured; custom credential fields require
   consumer rules.

These resolved points constitute the accepted answer to decision 11.

## References

- [Swift HTTP Types](https://github.com/apple/swift-http-types)
- [AsyncHTTPClient](https://github.com/swift-server/async-http-client)
