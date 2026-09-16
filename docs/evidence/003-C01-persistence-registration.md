# 003-C01: Persistent-system registration and version dispatch

- Date: 2026-09-16
- Plan: [003-C01](../plans/003-clean-slate-implementation.md#003-c01--persistent-system-registration-and-version-dispatch)
- Status: Complete locally; owner review is the next checkpoint.
- Authority: [Decision 7](../design-decisions/07-persistence-boundary.md),
  [Decision 8](../design-decisions/08-schema-compatibility.md),
  [Decision 9](../design-decisions/09-normalization-and-redaction.md), the
  [quality gates and CI policy](../quality-gates-and-ci.md), and the owner's
  2026-09-16 scope confirmation.

## Delivered boundary

`DioramaPersistence` is a new optional library product depending only on
`DioramaCore`. Core definitions and executions retain no persistence
requirement, and non-`Codable` prepared values remain valid for programmatic
in-memory use.

Envelope and system-payload schema versions use `UInt32` directly. Their
non-negative range includes zero and remains independent of package semantic
versions. C02 owns the exact version-one document representation.

Each immutable `PersistentSystemRegistration` declares:

- one stable `SystemTypeID`;
- one current payload version and current `Codable` reader/writer;
- zero or more explicit historical `Decodable` readers; and
- conversion between the system-owned payload and a prepared current
  `ScenarioAttachment`.

Registrations use Swift's synchronous, format-neutral `Encoder` and `Decoder`
protocols directly. They allow the later JSON document codec to provide a nested
payload position while the registry selects the concrete `Codable` type. No
JSON, file repository, resource storage, or publication behavior enters this
unit.

`PersistentSystemRegistry` rejects duplicate system registrations, dispatches
readers by the separately persisted system type and payload version, and
verifies that decoded content has the exact declared attachment key and system
type. Unknown system types, unsupported versions, incompatible decoded
identity are distinct structured errors containing no payload value. A missing
registration is consistently reported as an unknown system type during both
reading and writing because registrations are keyed by system type, not by
attachment.

Persistability validation visits every active attachment. Ignoring a configured
attachment does not bypass this check. Under the owner-approved prerequisite
policy, successfully loaded attachments absent from current setup are diagnosed
and discarded before candidate construction. The loader must still register,
decode, prepare, and validate their payloads before that reconciliation.

## Executable evidence

The focused persistence suite proves:

- non-negative payload version values from zero through `UInt32.max`;
- heterogeneous payload dispatch and several separately keyed instances of one
  system type;
- current writer metadata and explicit historical-reader conversion;
- duplicate system and duplicate version-reader rejection;
- consistent unknown-system failures across reading and writing, distinct from
  unsupported-version failures;
- exact decoded attachment identity enforcement;
- continued in-memory use of non-`Codable` values alongside publication
  refusal; and
- registration requirements for ignored active content.

Tests use private property-list coding proxies only to exercise the
format-neutral `Codable` boundary. They are not a Diorama product, supported
persistence format, or substitute for C02's deterministic JSON schema.

## Verification

- `scripts/lint` passes SwiftFormat lint and strict SwiftLint with no violations.
- `scripts/test` passes all 89 macOS tests with warnings as errors, the main
  release build, and the separate examples-package release build.
- `scripts/coverage ios` passes the iOS 18 deployment build, all 89 tests on the
  selected iPhone 17 / iOS 27.0 simulator, and multi-binary LCOV export including
  `DioramaPersistenceTests`.
- The pinned x86_64 `swiftlang/swift` Apple Container run passes all 89 Linux
  tests with warnings as errors, the main and examples release builds, and
  multi-binary LCOV export including `DioramaPersistenceTests`.

No dependency, JSON schema, file I/O, migration graph, opaque unknown-payload
preservation, random-system persistence registration, or runtime startup change
is introduced. C02 owns deterministic version-one JSON and the random payload
schema; C03 and later units own storage, loading, candidates, and publication.
