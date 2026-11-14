# 003-H07: Atomic document and HTTP body resources

The owner confirms H07 scope, GPT-6 Astra at `xhigh` reasoning, and a separate
branch stacked on H06 on 2026-11-11. The base is `17004ca`; the review branch is
`feat/003-h07-atomic-resources`.

## Capability and ownership

`JSONScenarioRepository` now collects the exact resources referenced by deliberate
system codecs before touching storage. It loads stable JSON and resolves
registered HTTP resources into immutable owned bytes during caller-established
publication exclusivity. Core stays
independent of persistence and HTTP. The first consumer proof registers actual
HTTP body values through the public persistent-system boundary; production
URLSession registration, automatic body placement/extensions, and Content-Length
remain in their owning units.

`HTTPBodyResource(path:bytes:)` accepts prepared bytes. A returned definition owns
its content before publication begins and after load finishes. Publication
failure, staging cleanup, replacement, and removal of the repository therefore
cannot invalidate those values. The result retains no execution, native adapter,
file handle, or resource resolver. Path-only resources exist only in the persisted
representation; decoding resolves them before runtime construction. Matching uses
owned resource bytes by default and preserves inline/resource equivalence.

## Reviewed implementation choices

The complete storage layout and consumer contracts are documented in
[resource files](../persistence-schema-v1.md#document-and-resource-files)
and [HTTP resource ownership](../http-message-schema-v1.md#resource-ownership).

- Published fixtures are ordinary `name.json` and sibling `name-resources/`
  files with stable literal names. Only unpublished staging uses random names.
  There are no published generation symlinks or retained generation directories.
- The owner-approved [DD07 amendment](../design-decisions/07-persistence-boundary.md#stable-file-layout-and-publication-exclusivity--owner-approved-2026-11-14)
  requires callers to exclude publication from loading/resource resolution,
  other publication, and manual edits of the same scenario. Returned HTTP values
  own bytes across replacement and fixture removal. Read-only loads and
  independent scenarios with disjoint paths may overlap.
- Complete staging and resource backups support returning-failure rollback before
  the JSON commit. A second rollback failure is reported separately and retains
  backups for caller recovery. Post-commit cleanup errors do not undo publication.
  No crash recovery automation or multi-entry filesystem transaction is promised.
- Resource names retain literal spaces, Unicode, and percent escapes; empty,
  dot, dot-dot, and NUL-containing components are rejected. File/directory prefix
  conflicts and case aliases fail before storage. Descriptor-based
  reads reject symlinks and nonregular content without blocking on FIFOs.
- File setup remains on trusted local Apple/Linux filesystems. Root ancestors
  are trusted; editing requires publication quiescence. No crash-durability or
  network-filesystem guarantee is added.
- Eager HTTP byte ownership costs memory proportional to referenced content.
  Recovery data may require manual cleanup after failures. There are no new
  dependencies, spooling, automatic placement, or digests.

## Earlier verification evidence

These original checkpoints describe the earlier generation layout; the stable
layout and exclusive-publication review below supersede those storage claims.

Tests cover exact non-UTF-8 content, inline/resource match equivalence,
prepared-only publication, literal authored edits, unresolved/missing resources,
duplicate and conflicting references, portable path aliases and traversal,
symlink and directory refusal, read-only loading, retained old snapshots,
concurrent last-writer publication, injected directory/write/link/commit failures,
cleanup failure retention, and retrying publication with caller-owned bytes.
Existing single-document and repository tests remain part of the regression gate.

Verification on the repository-selected Xcode 27.2 / Swift 6.4.2 toolchain:

- `swift test --filter 'HTTPResourceRepositoryTests|FileResourceStorageTests|JSONScenarioRepositoryTests|FileScenarioStorageTests'`:
  passes; subsequent added preparation/backend refusal tests pass in the full gates.
- `Scripts/check`: passes strict formatting/lint, 691 host tests, public authoring
  and resource-lifecycle compiler probes, release builds, and usage examples.
- `Scripts/coverage swiftpm macos`: passes with fresh products and LCOV export.
  Local H07 changed-line coverage is 244/254 executable lines (96.06%); hosted
  Codecov remains the authoritative required check.
- `Scripts/coverage ios`: passes release build, iPhone 17 / iOS 27.2 Simulator
  tests, public lifecycle compiler probes, and LCOV export.
- `Scripts/lint`: passes again after the final source documentation updates.
- `git diff --check 17004ca`: passes for the complete branch/worktree diff.
  Local file links and new section anchors resolve.

The first sandboxed Swift invocation cannot write the toolchain cache; successful
runs use normal cache access. Compiler errors in new test assertions and fixture
visibility, followed by line-length/trailing-comma lint failures, are corrected
before the passing gates. Xcode retains its existing no-AppIntents metadata
extraction notices; no Swift compiler or linter warnings are waived.

Local Linux is unavailable: `container system status` reports “apiserver is not
running and not registered with launchd.” No Linux execution or hosted CI result
is claimed. Required PR checks enforce the macOS/iOS/Linux and coverage matrix
before a separately authorized merge.

## Rebase verification — 2026-11-13

The owner requests rebasing H07 onto H06's PR branch. The rebase applies cleanly,
with an unchanged implementation patch. The base is H06 commit `17004ca`,
submitted in [PR #127](https://github.com/SwiftScream/diorama/pull/127).

`scripts/check` passes on the rebased branch on macOS, including all 691 host
tests, strict formatting/lint, compiler probes, release builds, and usage
examples. `git diff --check 17004ca` passes. This rebase adds no local iOS or
Linux validation. H07 remains a separate local review unit.

## Commit split verification — 2026-11-13

The owner requests separating system-independent persistence support from its
HTTP consumer. At the split checkpoint, both commits retain the original
production implementation, manifest, and existing tests byte-for-byte. Four new persistence repository
tests establish resource collection/resolution independently of HTTP.

- The persistence foundation passes 34 focused tests and `scripts/check` with
  all 690 macOS host tests. Its [evidence](003-H07-persistence-resources.md)
  records its independent scope and verification.
- The complete unit passes 39 focused tests across five suites and
  `scripts/check` with all 695 macOS host tests, strict formatting/lint,
  compiler probes, release builds, and usage examples.
- The complete branch diff against `17004ca` passes `git diff --check`;
  documentation file links and new section anchors resolve.
- H07 completion status and combined evidence belong to the HTTP integration
  commit. The persistence commit leaves the plan's H07 status unchanged.

Only macOS validation runs for this review update. The earlier iOS/coverage
results above describe the original implementation; no additional iOS, Linux,
or coverage execution is claimed for the split.

## Storage consolidation restack — 2026-11-13

The HTTP integration commit is restacked onto the amended persistence foundation.
The [foundation evidence](003-H07-persistence-resources.md#storage-organization-review--2026-11-13)
records the storage consolidation, private member restoration, and file-reader
extraction. The HTTP implementation and tests are unchanged.

The complete unit passes 39 focused tests and `scripts/check` with all 695 macOS
host tests, strict formatting/lint, compiler probes, release builds, and usage
examples. The complete branch diff passes `git diff --check`. No additional
platform or coverage validation runs for this update.

## Stable layout integration review — 2026-11-14

The owner approves stable Git-managed `name.json` and `name-resources/` paths
and exclusive publication for one scenario. The persistence
[review evidence](003-H07-persistence-resources.md#stable-file-layout-review--2026-11-14)
records the amended DD07 contract, rollback/recovery limits, 38 focused tests,
and the passing 694-test macOS foundation gate.

HTTP integration tests now inspect the stable resource directory directly,
including literal authored edits, exact prepared bytes, and the ordinary published
JSON/resource layout. Existing ownership checks still prove that successful
loads and fresh definitions remain usable after replacement, publication failure,
and fixture deletion. HTTP production source, payload schemas, and matching
behavior are unchanged by this layout update.

The full unit passes 43 focused tests across five suites and `scripts/check`
with all 699 macOS host tests, strict formatting/lint, compiler probes, release
builds, and usage examples. Documentation file links, new section anchors,
and the complete H07 `git diff --check` pass. Earlier iOS and coverage results
above describe the original implementation; only macOS validation runs for this
review update, with no new iOS/Linux or coverage execution claimed.

The plan conflict during restacking preserves the revised scope and unit
completion status. The owner approves the persistence and HTTP review changes and requests
squashing both fixups into their target commits. No push, PR, merge, or next-unit
work is implied.

## Persistence review restack — 2026-11-14

The owner requests squashing the approved complete-encoding and resource-path
fixups into persistence and restacking HTTP integration. The HTTP round-trip
test now compares both `.data` and `.resources` from the complete public encoder.
Path rejection tests and the HTTP schema follow the approved structural naming
rules; filesystem-specific names are no longer rejected by the shared path type.
HTTP production source and payload schemas are unchanged by this restack.

Validation on macOS passes all 18 focused HTTP message/resource tests and
`scripts/check`, including strict formatting/lint, all 700 host tests, compiler
probes, coverage-export fixtures, release builds, and usage examples.
`git diff --check` passes. No iOS, Linux, or new coverage collection runs.

## Owned resources and explicit resolution review — 2026-11-14

The owner approves removing path-only HTTP resource construction and the
`Content.unresolved` case. Every `HTTPBodyResource` now owns exact prepared bytes;
`bytes()` is nonthrowing. HTTP body decoding extracts the existing
`ScenarioDocumentSnapshot` through `ScenarioResourceCoding.resolutionContext(from:)`
at the Codable boundary and passes it explicitly into body conversion. The
persisted payload no longer constructs a temporary runtime body while parsing.
Conversion validates field combinations and the relative path before reading and
resolves each reference once. Missing context or bytes fails decoding; inline and
absent/unavailable standalone decoding remains supported. Encoding always has
owned HTTP bytes and no longer branches around an unresolved resource.

Component golden tests use explicit in-memory resource snapshots and retain
their exact JSON fixtures. Matching and body-profile tests use owned resources;
matcher resolver failures remain separately covered. Regression tests prove
request/response rejection without a context, byte-only scenario rejection for
resource-backed HTTP, valid empty ownership, no resource reads for malformed or
escaping references, and exactly one read for a valid conversion. Repository
failure, conflict, prepared-byte, and loaded-ownership tests remain covered.
DD17 records the approved API amendment; the decision index and HTTP/persistence
contracts describe it. Envelope and system payload schemas do not change.

Validation on macOS passes all 61 focused tests across six HTTP/persistence
suites and `scripts/check`, including strict formatting/lint, all 702 host tests,
compiler probes, coverage-export fixtures, release builds, and usage examples.
`git diff --check` passes. The source-breaking removal of path-only construction
and the nonthrowing byte accessor are intentional. No iOS, Linux, or new coverage
collection runs. The owner approves squashing this fixup into the HTTP integration
commit; the dependent H07A branch is restacked.

## Body payload enum refactor — 2026-11-14

The owner requests a separate refactor commit replacing `BodyPayload`'s string
discriminator and independent optional fields with an associated-value enum.
Its cases are absent, exact bytes, a validated relative resource path, and
unavailable. A private typed wire tag and explicit Codable implementation retain
the existing JSON shape. Text/base64 decoding and field-combination validation
produce one valid enum case before resource resolution; encoding retains the
lossless UTF-8/base64 selection and exact resource path syntax. Body conversion
switches over valid cases and cannot receive contradictory stored fields.

No public API, JSON fixture, schema version, resource ownership, or matching
behavior changes. Existing golden, canonicalization, malformed-input, lifecycle,
body-profile, matching, and resource-resolution tests provide regression coverage.

Validation on macOS passes all 61 focused tests across six HTTP/persistence
suites and `scripts/check`, including strict formatting/lint, all 702 host tests,
compiler probes, coverage-export fixtures, release builds, and usage examples.
`git diff --check` passes. No iOS, Linux, or new coverage collection runs. The
source refactor and this evidence form one separate `ref(http)` commit as requested.

## Review boundary

The owner approves H07 review and authorizes PR creation on 2026-11-14. Four
atomic commits deliver the unit in its final reviewed form:

1. `003-H07: feat(persistence): publish atomic document resources` contains
   persistence mechanics, storage and system-independent codec/repository tests,
   the persistence schema, and [foundation evidence](003-H07-persistence-resources.md).
2. `003-H07: feat(http): integrate atomic body resources` contains HTTP byte
   ownership, resource coding, matching, HTTP integration tests and schema,
   the owned-resource and explicit-resolution contract, and combined evidence.
3. `003-H07: ref(http): model body payloads as an enum` preserves JSON and public
   behavior while making invalid stored payload combinations unrepresentable.
4. `003-H07: docs(evidence): finalize review and plan status` records owner review
   approval and the owning plan's completed status for publication.

The complete review diff is against H06 at `17004ca`; it excludes the earlier
HTTP units and H07A. Required PR checks verify quality, macOS, iOS, Linux, and
coverage on the published revision. Merge and subsequent implementation work
still require separate owner instructions.
