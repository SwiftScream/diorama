# Diorama JSON persistence schema version 1

- Status: Complete locally under Plan 003-C02; owner review is pending
- Envelope version: `1`
- First-party random payload version: `1`
- Encoding: UTF-8 JSON

This document fixes the first deliberate persisted representation used by
Diorama. The schema represents prepared semantic scenario content. Repository
identity, destination paths, runtime modes, consumption state, package
versions, timestamps, and host metadata are not part of the document.

The envelope, header, and system entries are a format-neutral `Codable` object
model. `JSONScenarioCodec` is the canonical JSON transport for that model;
it does not own the schema structures or their validation rules. Its public
encoder accepts the core's immutable `ScenarioDefinition` and returns a complete
`ScenarioDocument` containing canonical JSON in `.data` and all referenced resource
bytes in `.resources`. Missing bytes or conflicting resource references fail
encoding. Resource-free scenarios return an empty resource dictionary. There is
no JSON-only scenario encoding method. The public decoder accepts JSON bytes and
returns `ScenarioDefinition`; resource resolution occurs through repository loading.
The `Codable` envelope is internal to persistence; the core model does not
require `Codable`. `JSONScenarioCodec.schemaVersion` identifies
the envelope version. Runtime `ScenarioConfiguration` is supplied separately at
startup and has no encoded representation.

## Document shape

The top level is an object containing exactly `diorama` and `systems`:

```json
{
  "diorama" : {
    "schemaVersion" : 1
  },
  "systems" : [
    {
      "attachmentKey" : "primary-random",
      "payload" : {
        "values" : [
          0,
          18446744073709551615
        ]
      },
      "schemaVersion" : 1,
      "type" : "diorama.random"
    }
  ]
}
```

The `diorama` object contains exactly one field:

- `schemaVersion` is the non-negative `UInt32` Diorama envelope version.
  Version 1 is the only version currently read or written.

`systems` is an array. Its order is semantic attachment order and is preserved
on decode and encode. Every entry contains exactly:

- `attachmentKey`: the scenario-local string key for this instance;
- `type`: the stable registered system type identifier;
- `schemaVersion`: the non-negative `UInt32` payload version owned by that
  system; and
- `payload`: the system-owned JSON value decoded by the explicitly registered
  reader for that type and version.

Attachment keys must be unique across the document, including attachments with
different system types. Unknown types, unsupported payload versions, and a
reader that returns a different attachment identity are rejected through the
persistence registry.

## Shared overridable field form

Importing `DioramaPersistence` makes `OverridableValue<Value>` conform to
`Codable` when `Value` does. An ordinary observation writes as the wrapped
value directly. An authored value writes as an object with one `override` key.
The reader also accepts an object with one `observed` key or both keys; when
both are present, the override wins. Tagged objects reject any other keys, and
an object with neither tag is invalid unless it is a valid raw `Value`.

The top-level `observed` and `override` keys are reserved by this coding form.
Systems with raw structured values using those keys must define another field
schema. Each system's payload version still controls whether a field uses this
form; the conformance does not add override behavior to other fields.

## Shared timestamp origin scalar

Core's package-visible `TimestampOrigin` normalizes native dates and parsed
ISO 8601 origins to milliseconds at construction, retaining a numeric UTC
display offset. Persistence's opt-in `TimestampOriginPayload` encodes that
validated value as the existing ISO 8601 string, without changing its instant
or offset. Core's semantic type remains independent of Codable. Systems own
their enclosing schema versions, origin placement, and override policies.

## Random payload version 1

The `diorama.random` payload is an object containing exactly `values`.
`values` is an ordered array of JSON unsigned integers in the inclusive range
`0...18446744073709551615`. Array order is the raw `RandomNumberGenerator.next()`
sequence. There are no timestamps, sequence fields, seeds, distributions, or
runtime source details.

Decoded values are validated and admitted as already-prepared content before
becoming the single `values` sequential track. Capture transformations are not
rerun. The canonical writer accepts only that exact track layout.
An attachment with a different layout fails with
`PersistentSystemEncodingError.invalidTrackLayout`.

## Canonical writing

The version-one writer emits:

- pretty-printed UTF-8 JSON;
- lexicographically sorted object keys;
- unchanged semantic array order;
- unescaped forward slashes;
- decimal JSON numbers for non-negative `UInt32` schema versions and random
  `UInt64` values;
- no volatile metadata; and
- exactly one trailing newline.

The committed fixtures under `Tests/DioramaPersistenceTests/Fixtures` are the
byte-level contract. In particular, `random-boundaries.json` independently
protects exact `UInt64.max` representation rather than relying only on a
writer/reader round trip. `random-example.json` is a compact, human-readable
scenario with two independently keyed random attachments for reviewing the
document shape.

## Strict reading and compatibility

Diorama-owned envelope and system-entry objects reject unknown fields. The
first-party random payload also rejects unknown fields. Missing fields, wrong
JSON kinds, schema versions outside `0...4294967295`, duplicate attachment
keys, malformed JSON, unknown system types, and unsupported envelope or payload
versions are not coerced or partially loaded. Zero is a valid version value but
remains unsupported until an explicit reader registers it.

An unversioned top-level value, including the earlier proof-of-concept exchange
array, is rejected as an unversioned envelope. A missing `diorama` header or a
header without `schemaVersion` has the same classification. A present but null,
nonnumeric, fractional, or out-of-range version is malformed. Version dispatch
never guesses a schema from the fields that happen to be present.

Structural failures report only schema-authored field names and array positions
as coding paths. Decoder descriptions and payload values are not retained in
these errors. Registered consumer systems own the strictness and compatibility
policy inside their payload object; this document fixes only the Diorama-owned
envelope and the first-party random payload.

There are no historical version readers because no earlier clean-slate schema
exists. Future public schema versions must retain version 1 readers within the
same major package series, as required by Decision 8.


## Shared bounded NSError payload

DioramaPersistence offers package-visible `NSErrorSnapshotPayload` as an
optional nested representation for first-party system schemas, approved by
[DD06](design-decisions/06-runtime-to-snapshot-conversion.md#shared-nserror-persistence-payload--owner-approved-2026-10-17).
It wraps Core's validated `NSErrorSnapshot`, without making Core's type
`Codable` or introducing a new registered system or envelope version.

The object contains `domain`, integral `code`, and a string-keyed `userInfo`
object. Every user-info value contains `type` and `value`. The type is one of
`string`, `integer`, `real`, `boolean`, `data`, `date`, `array`, or `dictionary`.
Integers retain Int64 precision, data uses Base64 in JSON, and dates use finite
Unix-second numbers preserving available submillisecond precision. Reals and
dates are not rounded by system-specific measurement precision rules.
Arrays contain tagged values; dictionaries contain string-keyed tagged values.
Unknown keys/cases and invalid scalar values are rejected. The complete decoded
snapshot must satisfy Core's nesting, count, byte, domain, and date bounds.

A system deliberately selects this representation as part of its independently
versioned payload. It still owns error capture, metadata filtering/redaction,
omission reporting, typed supplements, and schema compatibility. A change to
the shared representation must account for every adopting system's version
contract; sharing the codec does not silently change those schemas.

## Document and resource files

`ScenarioDocumentStorage` exposes `load()` returning an optional
`ScenarioDocumentSnapshot` and `publish(_:)` accepting `ScenarioDocument`.
A missing document returns nil; an empty document is a present snapshot.
Document-only backends explicitly return snapshots without resource resolution
and reject resource publication before writing. Deliberate system codecs use
`ScenarioResourceCoding` to collect prepared referenced bytes before publication
and resolve them before repository loading returns. Direct codec encoding collects
the same complete resource set as repository publication. Repeated equal references
share one resource; conflicting content and namespace aliases fail before storage.

The file layout uses stable ordinary paths suitable for Git:

```text
checkout.json
checkout-resources/
  bodies/reply.bin
```

The resource directory is the document's final-extension-free name plus
`-resources`, alongside the JSON file. Literal resource references remain relative
to this directory. Locations must have disjoint document and companion paths.
No symlink or random generation name enters the published layout. Schema versions,
canonical JSON, and exact prepared resource bytes are unchanged.

Resource paths are literal slash-separated relative names. Empty components,
leading/trailing slashes, `.` and `..` components, and embedded NULs are rejected.
Spaces, Unicode, and other filename characters are preserved without sanitizing
or percent decoding; filesystem-specific naming and length limits fail at I/O.
There is no ASCII whitelist, Windows device-name exclusion, or trailing-period
restriction. Case aliases and file/directory namespace conflicts remain rejected
before publication. Filesystem Unicode equivalence still applies. Reads and writes
remain within the scenario's resource directory; external references are deferred.

[DD07's amendment](design-decisions/07-persistence-boundary.md#stable-file-layout-and-publication-exclusivity--owner-approved-2026-11-14)
requires callers to exclude publication from loading, resource resolution, another
publication, and manual edits of the same scenario. `JSONScenarioRepository.load()`
includes decoding and all resource resolution in that loading window. Stored
snapshots must finish resolving before publication resumes; they do not preserve
old resource files across replacement. Returned semantic values own resolved
bytes and survive later replacement, failure, or fixture removal. Read-only loads
may overlap one another; independent scenarios with disjoint paths may publish
concurrently. No automatic locks or cross-process coordination enforce exclusivity.

Registered codecs can extract the `ScenarioDocumentSnapshot` resource-resolution
context with `ScenarioResourceCoding.resolutionContext(from:)` at their Codable
boundary and pass it explicitly into conversion. HTTP requires this context for
resource-backed bodies and constructs only values owning resolved bytes; missing
context or unavailable content fails decoding. The generic optional
`ScenarioResourceCoding.decode(at:from:)` helper remains available to other codecs.

Publication stages complete content in a private temporary directory. Existing
resources move to a backup, new resources move to the stable companion location,
and JSON is replaced by atomic rename. Supported readers cannot observe the
intermediate states because publication is exclusive. Resource-free publication
removes the old resource folder; obsolete files are not retained between versions.
Document-only scenarios without an existing resource folder retain single-file
atomic publication. Temporary names are implementation state, never references.

Returning failures before the JSON commit restore the previous resources.
`FileStorageError.rollbackFailure` reports an additional failed restoration;
in that case staging retains recovery bytes, and callers must recover the fixture
before using it again. Stage/commit errors retain cleanup evidence when rollback
succeeds. Cleanup failure after commit is returned in `DocumentPublication`
and does not undo publication. Process termination can leave staging or a partial
transition requiring caller recovery. Neither crash durability nor automatic
recovery is promised. The two sibling entries are not one filesystem transaction.

Resource reads reject symlinks and nonregular files, including unsafe path
components; names are never percent-decoded. Root ancestors are trusted. Replay
performs no writes, directory creation, locks, or cleanup and supports read-only
fixtures on local Apple/Linux filesystems. Remote filesystem behavior is outside
the contract.

See [persistence evidence](evidence/003-H07-persistence-resources.md) for the
layout, ownership, rollback, and failure tests.
