# URLSession failure component version 1

`DioramaURLSession.URLSessionFailure` is a thin snapshot-backed failure value for
`DioramaHTTP`'s generic lifecycle types. It establishes approximate native error
capture, preparation, persistence, and reconstruction. Native URLSession
observation, metadata policy, cancellation provenance, delivery, capabilities,
and system registration remain adapter work.

## Semantic value and preparation

The value contains only Core's package-visible `NSErrorSnapshot`. Public
`domain` and `code` expose its identity, including unknown numeric codes and
non-URL domains. `init(domain:code:)` constructs a failure without metadata.
`makeError()` returns `any Error`. It reconstructs a fresh NSError containing
supported user information and explicitly wraps `NSURLErrorDomain` values with
`URLError(_nsError:)`; other domains return the NSError directly. The returned
URL-domain error therefore casts to URLError without relying on automatic
NSError bridging, which is unavailable on the tested Linux runtime. The stable
value does not conform to
`Error`. Construction/decoding errors and Core preparation failures remain
separate infrastructure failures. HTTP 4xx/5xx statuses remain responses.

`capture(_:preparation:reporter:context:)` delegates native extraction to the
shared snapshot helper and then runs consumer-selected `ValuePreparation`.
Redaction precedes normalization and final validation. `admitPrepared` validates
decoded or programmatic baseline values without rerunning capture transforms.
A preparation closure can inspect a reconstructed error as NSError, edit a copy
of its
user information, and recapture it with the default preparation to construct a
replacement value. No custom user-info accessors are provided.

The default preserves supported values, including arbitrary strings and explicit
localized-description entries. Structural support does not establish
confidentiality. Consumers own redaction of credentials, URL content, descriptions,
and other metadata before admission. Encoding performs no transforms.

Unsupported native entries produce sorted `nativeErrorMetadataOmitted` facts
containing only their keys and reflected types. Entry values and descriptions
are never rendered in diagnostics. Omission has `.none` recording impact;
unrepresentable identity or failed preparation invalidates the candidate and
returns safe failure evidence. Capture never mutates the input error.

Later record/passthrough adapters must deliver the original live error, including
when capture fails; passthrough needs no capture. Replay supplies a fresh native
error, without original object identity, custom subclasses, or underlying-error
graphs. Observed caller cancellation is runtime control and must be classified
before capture; independently observed dependency cancellation is recordable.
The numeric error code alone does not establish cancellation provenance.

## Shared metadata representation

All keys and error domains use the same bounded structural rules. Supported
values are strings, URLs, signed 64-bit integers, finite real numbers, Booleans,
data, dates, arrays, and string-keyed dictionaries. See the
[shared payload contract](persistence-schema-v1.md#shared-bounded-nserror-payload)
for exact tags and validation. Shared bounds are depth 4, 128 values, 32 entries
per collection, 256 UTF-8 bytes per domain/key, 4,096 per string/URL spelling,
16,384 per data value, and 65,536 combined key/string/URL/data bytes.

URL values stay in `userInfo` under their original keys and reconstruct as
native URLs. String values remain strings. No failing-URL field, alias
precedence, alias synthesis, recognized-code name, reason accessor, or
URLSession-specific key allowlist is defined. This follows
[DD17's owner-approved simplification](design-decisions/17-http-lifecycle-composition.md#snapshot-backed-failure-foundation--owner-approved-2026-11-15).

## Persisted component

```json
{
  "version": 1,
  "error": {
    "domain": "NSURLErrorDomain",
    "code": -1009,
    "userInfo": {
      "url": {
        "type": "url",
        "value": "https://example.invalid/fixture"
      }
    }
  }
}
```

`version` and `error` are required. `error` uses Persistence's package-visible
`NSErrorSnapshotPayload`, with required `domain`, `code`, and `userInfo`.
Every metadata value has explicit `type` and `value` fields. An empty metadata
object is `{}`. Unknown fields/tags/versions, missing or null required fields,
wrong types, and invalid or out-of-bounds values are rejected before use.
Native omission leniency does not apply to edited persisted values.

This independently versioned component is unreleased. The owner approves replacing
H09's earlier unmerged component shape with this smaller version-one contract;
no reader for that review prototype is retained. The [URLSession registration](http-message-schema-v1.md#urlsession-registration-and-replay-setup)
owns the enclosing payload version and compatibility policy.

The [canonical fixture](../Tests/DioramaURLSessionTests/Fixtures/failures.json)
uses sorted keys, pretty printing, unescaped slashes, and a final newline.
The codec composes with both pre-response and response-owned partial-body
failure leaves in the [HTTP lifecycle](http-message-schema-v1.md).
