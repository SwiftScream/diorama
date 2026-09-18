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
model. `JSONScenarioCodec` is the canonical JSON byte transport for that model;
it does not own the schema structures or their validation rules.

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

## Random payload version 1

The `diorama.random` payload is an object containing exactly `values`.
`values` is an ordered array of JSON unsigned integers in the inclusive range
`0...18446744073709551615`. Array order is the raw `RandomNumberGenerator.next()`
sequence. There are no timestamps, sequence fields, seeds, distributions, or
runtime source details.

Decoded values are validated and admitted as already-prepared content before
becoming the single `values` sequential track. Capture transformations are not
rerun. The canonical writer accepts only that exact track layout.

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
array, is rejected as an unversioned envelope. Version dispatch never guesses a
schema from the fields that happen to be present.

Structural failures report only schema-authored field names and array positions
as coding paths. Decoder descriptions and payload values are not retained in
these errors. Registered consumer systems own the strictness and compatibility
policy inside their payload object; this document fixes only the Diorama-owned
envelope and the first-party random payload.

There are no historical version readers because no earlier clean-slate schema
exists. Future public schema versions must retain version 1 readers within the
same major package series, as required by Decision 8.
