# 003-C02: Deterministic version-one JSON and random schema

- Date: 2026-09-16
- Plan: [003-C02](../plans/003-clean-slate-implementation.md#003-c02--deterministic-version-one-json-and-random-schema)
- Status: Complete locally; owner review is the next checkpoint.
- Authority: [Decision 8](../design-decisions/08-schema-compatibility.md),
  [Decision 9](../design-decisions/09-normalization-and-redaction.md),
  [Decision 13](../design-decisions/13-random-proving-system.md), the
  [version-one schema](../persistence-schema-v1.md), and the owner's 2026-09-16
  scope and model-choice confirmation.

## Delivered boundary

`PersistedScenarioEnvelope`, its header, and its system entries form one
format-neutral `Codable` object model using the registrations introduced by
C01. Version 1 stores an explicit Diorama envelope header and an ordered array
of independently typed and versioned system entries. `JSONScenarioCodec` is a
thin byte-transport wrapper around that model. Repository identity and runtime
modes remain outside the persisted semantic document.

Canonical output uses Foundation `JSONEncoder` with pretty printing, sorted
keys, unescaped slashes, semantic array order, UTF-8 bytes, and one trailing
newline. It carries no package version, timestamp, process identity, or path.

The reader selects envelope version 1 before decoding payloads. Diorama-owned
envelope, header, and system-entry objects reject unknown fields. Structural
errors retain only safe schema field names and array positions. Unversioned
proof-of-concept arrays, malformed values, versions outside the non-negative
`UInt32` range, duplicate attachment keys, unsupported envelope versions, and
registry dispatch failures remain distinct evidence. Zero is decoded as a valid
version value and dispatched as unsupported when no reader registers it.

`DioramaRandomPersistence.registration` owns the deliberate version-one random
payload. Its sole `values` array stores ordered decimal `UInt64` values without
timestamps or source details. Decoding validates and admits every value as an
already-prepared random value before constructing its one strict track; it does
not rerun capture transformations or create a diagnostic reporter. Encoding
rejects any other track layout.

`DioramaCore` gains no `Codable`, JSON, or persistence dependency. The random
target adds only the repository's first-party `DioramaPersistence` product; no
third-party dependency is introduced.

## Executable evidence

Committed fixtures independently cover empty random content, `0` and
`UInt64.max`, an unversioned POC-shaped array, unknown fields at every owned
nesting level, malformed random values, unsupported envelope and payload
versions, zero envelope and payload versions, and payload versions below zero
and above `UInt32.max`.

The focused tests prove:

- byte-for-byte canonical output against independent fixtures;
- exact full-range `UInt64` decoding and repeat encoding;
- empty documents and several separately keyed random instances;
- preservation of semantic system and value array order;
- strict unknown-field rejection with safe deterministic coding paths;
- reuse of the same object model through a binary property-list encoder and
  decoder, without the JSON transport;
- independent envelope and payload version dispatch;
- valid zero-version dispatch plus rejection of malformed, unversioned,
  out-of-range, and duplicate content; and
- absence of volatile metadata and incidental slash escaping.

## Verification

- `swift test --filter 'PersistedScenarioCodingTests|JSONScenarioCodecTests'`
  passes all 15 focused tests.
- `scripts/check` passes SwiftFormat lint, strict SwiftLint, all 105 macOS
  tests with warnings as errors, the main release build, and the separate
  examples-package release build.
- `scripts/coverage ios` passes the iOS 18 deployment build, all 105 tests on
  the selected iPhone 17 / iOS 27.0 simulator, and multi-binary LCOV export
  including `DioramaPersistenceTests` and its committed fixtures.
- The pinned x86_64 `swiftlang/swift` Apple Container run passes all 105 Linux
  tests with warnings as errors, the main and examples release builds, and
  multi-binary LCOV export. The byte-golden tests pass unchanged on macOS, iOS,
  and Linux.

No file repository, atomic replacement, resources, runtime loading, migration
for nonexistent schemas, generic metadata, YAML, coercive decoding, scenario
publication, or POC importer is introduced. C03 owns storage and atomic file
replacement; C04 owns loading against runtime setup.
