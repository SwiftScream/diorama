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

Values are immutable, Sendable, and Hashable. Heads retain HTTP Types equality
semantics (including case-insensitive field names and status-code equality).
Codecs additionally preserve original field-name spelling and reason phrases.
Bodies belong to the later response lifecycle, rather than `HTTPResponseHead`.
`HTTPRequestBody` cannot express unavailable content; `HTTPResponseBody` can.
Resource construction never accesses the filesystem. Resolution, publication,
containment checks against symlinks, and byte comparison belong to later resource
consumers. Inline versus resource storage does not change logical byte semantics.

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
schema. A resource path is a nonempty slash-separated relative path;
empty, dot, dot-dot, backslash, colon, and control-character components are
rejected. Percent escapes are literal path text. These are semantic references,
not filesystem handles or proof of resource existence.

All objects reject unknown keys, missing required fields, explicit nulls,
unknown body tags, and fields incompatible with the selected body case. The
canonical JSON transport follows the existing repository convention: sorted
object keys, pretty printing, unescaped slashes, semantic array order, and one
trailing newline. The component Codable conformances do not configure encoders.
Canonical request and response fixtures live in `Tests/DioramaHTTPTests/Fixtures`.

Preparation/redaction, matching, derived Content-Length, resource loading,
stream delivery, lifecycle conclusions, and native conversion are separate plan
units. These builders do not perform those operations or authorize persisting
unprepared secrets.

## Recording placement policy

[DD17's owner-approved storage amendment](design-decisions/17-http-lifecycle-composition.md#type-aware-body-storage--owner-approved-2026-11-08)
separates this codec from future automatic resource selection. Plan 003 H07 adds
resource mechanics; H07A adds configurable type-aware placement, thresholds, and
extensions. Images default to resources; text and other content default to
resources above 200 prepared bytes. JSON/HTML resources use `.json`/`.html` where
appropriate. These are planned recording behaviors, not implemented by this codec.
Replay honors stored content. H08 owns derived Content-Length and edited-body
consistency. See the [owning plan](plans/003-clean-slate-implementation.md#003-h07a--configurable-type-aware-body-storage-policy)
for prerequisites, exclusions, and the required future scope checkpoint.
